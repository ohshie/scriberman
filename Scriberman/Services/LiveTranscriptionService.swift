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
    private var buffers: [AudioSource: [Float]] = [:]
    private var audioConverters: [AudioSource: AudioConverter] = [:]
    
    // Timing
    private var chunkStartTimes: [AudioSource: Date] = [:]
    private var totalSamplesProcessed: [AudioSource: Int] = [:]

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
        
        buffers.removeAll()
        totalSamplesProcessed.removeAll()
        chunkStartTimes.removeAll()
        audioConverters.removeAll()
        collectedFinalSegments.removeAll()

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
    }

    func stop() async -> [TranscriptSegment] {
        logger.info("Stopping live transcription service")

        // Process any remaining audio in the buffers
        for (source, buffer) in buffers {
            if !buffer.isEmpty {
                let currentOffset = Float(totalSamplesProcessed[source] ?? 0) / Self.SAMPLE_RATE
                await processChunk(samples: buffer, source: source, currentOffset: currentOffset)
            }
        }

        let segments = collectedFinalSegments
        
        // Cleanup
        collectedFinalSegments.removeAll()
        buffers.removeAll()
        totalSamplesProcessed.removeAll()
        chunkStartTimes.removeAll()
        audioConverters.removeAll()
        asrManager = nil
        diarizer = nil
        
        return segments
    }

    // MARK: - Audio Processing

    func process(samples: [Float], source: AudioSource, sampleRate: Double) async {
        do {
            if audioConverters[source] == nil {
                audioConverters[source] = AudioConverter()
            }
            let resampled = try audioConverters[source]!.resample(samples, from: sampleRate)
            guard !resampled.isEmpty else { return }

            if chunkStartTimes[source] == nil {
                chunkStartTimes[source] = .now
            }

            var currentBuffer = buffers[source] ?? []
            currentBuffer.append(contentsOf: resampled)

            if currentBuffer.count >= Self.CHUNK_SAMPLES {
                let chunkToProcess = currentBuffer
                currentBuffer.removeAll()
                buffers[source] = currentBuffer
                chunkStartTimes[source] = nil
                
                let currentOffset = Float(totalSamplesProcessed[source] ?? 0) / Self.SAMPLE_RATE
                totalSamplesProcessed[source] = (totalSamplesProcessed[source] ?? 0) + chunkToProcess.count
                
                await processChunk(samples: chunkToProcess, source: source, currentOffset: currentOffset)
            } else {
                buffers[source] = currentBuffer
            }
        } catch {
            logger.error("Error processing live audio (\(source.rawValue)): \(error.localizedDescription)")
        }
    }

    private func processChunk(samples: [Float], source: AudioSource, currentOffset: Float) async {
        guard let asrManager = asrManager else { return }

        let chunkDuration = Float(samples.count) / Self.SAMPLE_RATE
        
        do {
            let maxAmplitude = samples.map { abs($0) }.max() ?? 0.0
            
            logger.info("🎤 Transcribing \(source.rawValue) chunk (\(samples.count) samples = \(String(format: "%.1f", chunkDuration))s, max amplitude: \(String(format: "%.6f", maxAmplitude)))...")
            
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
            
            logger.info("📝 RESULT [\(source.rawValue)]: \(speakerID): \(cleanedText)")
            
            let segment = TranscriptSegment(
                speakerId: speakerID,
                text: cleanedText,
                startTime: currentOffset,
                endTime: currentOffset + chunkDuration,
                audioSource: source,
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
