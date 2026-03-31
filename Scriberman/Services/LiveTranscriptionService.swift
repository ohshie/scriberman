import AVFoundation
import FluidAudio
import Foundation
import OSLog

actor LiveTranscriptionService {
    private let logger = Logger(subsystem: "Scriberman", category: "LiveTranscriptionService")
    
    // Core managers
    private var asrManager: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    
    // Audio processing constants
    private static let CHUNK_SECONDS: Float = 5.0
    private static let SAMPLE_RATE: Float = 16000
    private static let CHUNK_SAMPLES = Int(SAMPLE_RATE * CHUNK_SECONDS)
    
    // Chunk accumulation buffers
    private var micBuffer: [Float] = []
    private var audioConverter: AudioConverter?
    
    // Timing
    private var chunkStartTime: Date?
    private var totalSamplesProcessed: Int = 0

    // Authoritative record of all final segments accumulated this session
    private var collectedFinalSegments: [TranscriptSegment] = []

    nonisolated(unsafe) private let resultsTuple: (stream: AsyncStream<TranscriptSegment>, continuation: AsyncStream<TranscriptSegment>.Continuation)

    nonisolated var transcriptStream: AsyncStream<TranscriptSegment> {
        resultsTuple.stream
    }

    init() {
        self.resultsTuple = AsyncStream<TranscriptSegment>.makeStream()
    }

    // MARK: - Lifecycle

    func start(workspace: Workspace) async throws {
        logger.info("Starting live transcription service (Offline Chunking Mode)")
        
        micBuffer.removeAll()
        totalSamplesProcessed = 0
        collectedFinalSegments.removeAll()
        chunkStartTime = nil

        let resolver = ModelPathResolver()

        // 1. Initialize offline ASR
        let asrConfig = ASRConfig()
        let asr = AsrManager(config: asrConfig)
        let asrModels = try await AsrModels.downloadAndLoad()
        try await asr.initialize(models: asrModels)
        self.asrManager = asr
        logger.info("AsrManager initialized")

        // 2. Initialize offline Diarizer
        let offlineDiarizer = OfflineDiarizerManager(config: .default)
        let diarizerModels = try await OfflineDiarizerModels.load(from: workspace.modelsURL)
        offlineDiarizer.initialize(models: diarizerModels)
        self.diarizer = offlineDiarizer
        logger.info("OfflineDiarizerManager initialized")

        audioConverter = AudioConverter()
    }

    func stop() async -> [TranscriptSegment] {
        logger.info("Stopping live transcription service")

        // Process any remaining audio in the buffer
        if !micBuffer.isEmpty {
            let remainingSamples = micBuffer
            micBuffer.removeAll()
            await processChunk(samples: remainingSamples)
        }

        let segments = collectedFinalSegments
        
        // Cleanup
        collectedFinalSegments.removeAll()
        asrManager = nil
        diarizer = nil
        audioConverter = nil
        
        return segments
    }

    // MARK: - Audio Processing

    func process(samples: [Float], source: AudioSource, sampleRate: Double) async {
        // We only process mic right now in this simple live implementation
        guard source == .mic else { return }
        
        do {
            if audioConverter == nil {
                audioConverter = AudioConverter()
            }
            let resampled = try audioConverter!.resample(samples, from: sampleRate)
            guard !resampled.isEmpty else { return }

            if chunkStartTime == nil {
                chunkStartTime = .now
            }

            micBuffer.append(contentsOf: resampled)

            if micBuffer.count >= Self.CHUNK_SAMPLES {
                let chunkToProcess = micBuffer
                micBuffer.removeAll()
                chunkStartTime = nil
                
                await processChunk(samples: chunkToProcess)
            }
        } catch {
            logger.error("Error processing live audio: \(error.localizedDescription)")
        }
    }

    private func processChunk(samples: [Float]) async {
        guard let asrManager = asrManager else { return }

        let chunkDuration = Float(samples.count) / Self.SAMPLE_RATE
        let currentOffset = Float(totalSamplesProcessed) / Self.SAMPLE_RATE
        totalSamplesProcessed += samples.count
        
        do {
            let maxAmplitude = samples.map { abs($0) }.max() ?? 0.0
            
            logger.info("🎤 Transcribing chunk (\(samples.count) samples = \(String(format: "%.1f", chunkDuration))s, max amplitude: \(String(format: "%.6f", maxAmplitude)))...")
            
            if maxAmplitude < 0.001 {
                logger.info("⚠️ AUDIO IS SILENT - Skipping transcription")
                return
            }

            let asrResult = try await asrManager.transcribe(samples, source: .system)
            let cleanedText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleanedText.isEmpty else {
                logger.info("⚠️ TRANSCRIPTION RETURNED EMPTY - ASR failed to detect speech")
                return
            }

            var speakerID = "unknown"
            
            if let diarizer = diarizer {
                logger.info("🔊 Diarizing chunk...")
                do {
                    let diarizationResult = try await diarizer.process(audio: samples)
                    
                    if let longestSegment = findLongestSpeaker(from: diarizationResult) {
                        speakerID = "speaker_\(longestSegment.speakerId)"
                        let duration = longestSegment.endTimeSeconds - longestSegment.startTimeSeconds
                        logger.info("📍 Longest speaker: \(speakerID) (\(String(format: "%.1f", duration))s)")
                    } else {
                        logger.info("📍 No speaker detected in audio chunk")
                    }
                } catch {
                    logger.error("Diarization failed: \(error)")
                }
            }
            
            logger.info("📝 RESULT: \(speakerID): \(cleanedText)")
            
            let segment = TranscriptSegment(
                speakerId: speakerID,
                text: cleanedText,
                startTime: currentOffset,
                endTime: currentOffset + chunkDuration,
                audioSource: .mic,
                isFinal: true
            )
            
            collectedFinalSegments.append(segment)
            resultsTuple.continuation.yield(segment)

        } catch {
            logger.error("Chunk processing failed: \(error)")
        }
    }
    
    private func findLongestSpeaker(from result: DiarizationResult) -> TimedSpeakerSegment? {
        var longestSegment: TimedSpeakerSegment? = nil
        var maxDuration: Float = 0

        for segment in result.segments {
            let duration = segment.endTimeSeconds - segment.startTimeSeconds
            if duration > maxDuration {
                maxDuration = duration
                longestSegment = segment
            }
        }

        return longestSegment
    }
}
