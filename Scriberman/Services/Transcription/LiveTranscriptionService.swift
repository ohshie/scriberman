import AVFoundation
import FluidAudio
import Foundation
import OSLog

enum LiveTranscriptionError: Error {
    case initializationFailed
}

actor LiveTranscriptionService {
    private let logger = Logger(subsystem: "Scriberman", category: "LiveTranscriptionService")
    private let fileManager = FileManager.default
    private let modelPathResolver = ModelPathResolver()

    // Core managers
    private var asrManager: AsrManager?
    private var diarizer: DiarizerManager?

    // Dependencies
    private let speakerEmbeddingStore: SpeakerEmbeddingStore?

    // Model initialization guard (tasks 4.1, 4.2)
    private(set) var isInitialized = false

    // Audio processing constants (task 2.1: 5.0 → 10.0)
    private static let SAMPLE_RATE: Float = 16000

    // Chunk accumulation state
    private let liveBuffer = LiveTranscriptionBuffer()
    private var audioConverters: [AudioSource: AudioConverter] = [:]

    // Authoritative record of all final segments accumulated this session
    private var collectedFinalSegments: [TranscriptSegment] = []

    // Speaker tracking across session (task 3.4)
    // Key: session-local speaker ID ("speaker_SPEAKER_0" etc.)
    // Value: (embedding, wasMatched, matchedProfileID)
    var sessionSpeakers: [String: (embedding: [Float], wasMatched: Bool, matchedProfileID: UUID?)] = [:]

    nonisolated(unsafe) private let resultsTuple: (stream: AsyncStream<TranscriptSegment>, continuation: AsyncStream<TranscriptSegment>.Continuation)

    nonisolated var transcriptStream: AsyncStream<TranscriptSegment> {
        resultsTuple.stream
    }

    // task 3.1: SpeakerEmbeddingStore injected via init
    init(speakerEmbeddingStore: SpeakerEmbeddingStore? = nil) {
        self.speakerEmbeddingStore = speakerEmbeddingStore
        self.resultsTuple = AsyncStream<TranscriptSegment>.makeStream()
    }

    // MARK: - Model Pre-warming (task 4.1)

    /// Loads ASR and diarizer models without starting the audio pipeline.
    /// Idempotent: subsequent calls are no-ops if already initialized.
    func prepare(workspace: Workspace) async {
        guard !isInitialized else {
            logger.info("LiveTranscriptionService already initialized, skipping prepare()")
            return
        }

        logger.info("Pre-warming live transcription models...")

        // 1. Initialize ASR
        do {
            let asrConfig = ASRConfig()
            let asr = AsrManager(config: asrConfig)
            let asrDirectory = try modelPathResolver.modelDirectory(for: .asrParakeetV3, in: workspace)
            let asrModels = try await AsrModels.load(from: asrDirectory)
            try await asr.initialize(models: asrModels)
            self.asrManager = asr
            logger.info("AsrManager initialized")
        } catch {
            logger.error("ASR initialization failed during prepare(): \(error). Live transcription unavailable.")
            // Leave isInitialized = false so start() can surface the error
            asrManager = nil
            diarizer = nil
            return
        }

        // 2. Initialize DiarizerManager with retry (task 1.2, 1.3, 1.5)
        let diarizerConfig = DiarizerConfig(
            clusteringThreshold: 0.5,
            minSpeechDuration: 0.5,
            minSilenceGap: 0.2
        )
        let mgr = DiarizerManager(config: diarizerConfig)

        let diarizerRepo: URL
        do {
            diarizerRepo = try modelPathResolver.modelDirectory(for: .offlineDiarization, in: workspace)
        } catch {
            logger.error("Diarizer initialization failed during prepare(): missing workspace diarizer repo — \(error).")
            asrManager = nil
            diarizer = nil
            return
        }
        let segmentationURL = diarizerRepo.appendingPathComponent("pyannote_segmentation.mlmodelc", isDirectory: true)
        let embeddingURL = diarizerRepo.appendingPathComponent("wespeaker_v2.mlmodelc", isDirectory: true)
        guard fileManager.fileExists(atPath: segmentationURL.path), fileManager.fileExists(atPath: embeddingURL.path) else {
            logger.error("Diarizer initialization failed during prepare(): missing workspace diarizer files.")
            asrManager = nil
            diarizer = nil
            return
        }

        do {
            let models = try await DiarizerModels.load(
                localSegmentationModel: segmentationURL,
                localEmbeddingModel: embeddingURL
            )
            mgr.initialize(models: models)
            self.diarizer = mgr
            logger.info("DiarizerManager initialized from workspace models")
        } catch {
            logger.error("Diarizer initialization failed during prepare(): \(error). Live transcription unavailable.")
            asrManager = nil
            diarizer = nil
            return
        }

        isInitialized = true
        logger.info("LiveTranscriptionService pre-warming complete (diarizer available: \(self.diarizer != nil))")
    }

    // MARK: - Lifecycle

    func start(workspace: Workspace) async throws {
        logger.info("Starting live transcription service (Offline Chunking Mode)")

        await liveBuffer.reset()
        audioConverters.removeAll()
        collectedFinalSegments.removeAll()
        sessionSpeakers.removeAll()

        // task 4.2: skip model loading if already initialized by prepare()
        if !isInitialized {
            await prepare(workspace: workspace)
        }

        guard isInitialized, asrManager != nil, diarizer != nil else {
            throw LiveTranscriptionError.initializationFailed
        }

        logger.info("LiveTranscriptionService started (diarizer: \(self.diarizer != nil))")
    }

    func stop() async -> [TranscriptSegment] {
        logger.info("Stopping live transcription service")

        // Process any remaining audio in the buffers
        let remainingBuffers = await liveBuffer.remainingBuffers()
        for (source, buffer) in remainingBuffers {
            if !buffer.isEmpty {
                let currentOffset = await liveBuffer.currentOffset(for: source)
                await processChunk(samples: buffer, source: source, currentOffset: currentOffset)
            }
        }

        // tasks 3.5, 3.6: Speaker enrollment at session end
        if let store = speakerEmbeddingStore, !sessionSpeakers.isEmpty {
            do {
                let allProfiles = try await store.fetchAll()
                let existingCount = allProfiles.count
                var newSpeakerIndex = 0

                // Sort by session-local ID for deterministic name assignment
                for sessionLocalId in sessionSpeakers.keys.sorted() {
                    guard let info = sessionSpeakers[sessionLocalId] else { continue }

                    if info.wasMatched, let profileID = info.matchedProfileID {
                        // task 3.6: refresh lastSeen for matched speaker
                        try? await store.updateProfile(id: profileID)
                        logger.info("Updated lastSeen for matched speaker \(sessionLocalId)")
                    } else if !info.embedding.isEmpty {
                        // task 3.5: enroll new unmatched speaker with auto-generated name
                        let name = "Speaker \(existingCount + newSpeakerIndex + 1)"
                        newSpeakerIndex += 1
                        try? await store.enrollSpeaker(name: name, embedding: info.embedding)
                        logger.info("Enrolled new speaker '\(name)' for session speaker \(sessionLocalId)")
                    }
                }
            } catch {
                logger.error("Failed to read speaker profiles during stop(): \(error)")
            }
        }

        let segments = collectedFinalSegments

        // Cleanup — reset isInitialized so next session creates a fresh DiarizerManager
        collectedFinalSegments.removeAll()
        sessionSpeakers.removeAll()
        await liveBuffer.reset()
        audioConverters.removeAll()
        asrManager = nil
        diarizer = nil
        isInitialized = false

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

            if let chunkToProcess = await liveBuffer.append(samples: resampled, source: source) {
                let currentOffset = await liveBuffer.takePendingChunkOffset(for: source) ?? 0
                await processChunk(samples: chunkToProcess, source: source, currentOffset: currentOffset)
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

            // task 2.2: pass correct ASR source based on audio origin
            // (.microphone for mic, .system for app — inferred as FluidAudio.AudioSource from call-site)
            let asrResult = try await asrManager.transcribe(
                samples,
                source: source == .mic ? .microphone : .system
            )
            let cleanedText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleanedText.isEmpty else {
                logger.info("⚠️ TRANSCRIPTION RETURNED EMPTY - ASR failed to detect speech")
                return
            }

            var speakerID = "unknown"

            if let diarizer = diarizer {
                logger.info("🔊 Diarizing chunk...")
                do {
                    // task 1.4: use synchronous performCompleteDiarization instead of async process(audio:)
                    let diarizationResult = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)

                    if let longestSegment = findLongestSpeaker(from: diarizationResult) {
                        let sessionLocalId = "speaker_\(longestSegment.speakerId)"
                        let embedding = longestSegment.embedding
                        let duration = longestSegment.endTimeSeconds - longestSegment.startTimeSeconds

                        // tasks 3.2, 3.3: match embedding against SpeakerEmbeddingStore
                        if let store = speakerEmbeddingStore, !embedding.isEmpty {
                            if let match = await store.findBestMatch(embedding: embedding) {
                                // Known speaker recognized
                                speakerID = match.name
                                // task 3.4: accumulate matched speaker info (keep latest embedding)
                                sessionSpeakers[sessionLocalId] = (
                                    embedding: embedding,
                                    wasMatched: true,
                                    matchedProfileID: match.id
                                )
                                logger.info("📍 Matched speaker: \(speakerID) (profile match, \(String(format: "%.1f", duration))s)")
                            } else {
                                // Unknown speaker — use session-local ID
                                speakerID = sessionLocalId
                                // task 3.4: accumulate unmatched speaker info (only set once per speaker)
                                if sessionSpeakers[sessionLocalId] == nil {
                                    sessionSpeakers[sessionLocalId] = (
                                        embedding: embedding,
                                        wasMatched: false,
                                        matchedProfileID: nil
                                    )
                                }
                                logger.info("📍 New/unmatched speaker: \(speakerID) (\(String(format: "%.1f", duration))s)")
                            }
                        } else {
                            // No store or empty embedding — use session-local ID
                            speakerID = sessionLocalId
                            if sessionSpeakers[sessionLocalId] == nil && !embedding.isEmpty {
                                sessionSpeakers[sessionLocalId] = (
                                    embedding: embedding,
                                    wasMatched: false,
                                    matchedProfileID: nil
                                )
                            }
                            logger.info("📍 Longest speaker: \(speakerID) (\(String(format: "%.1f", duration))s)")
                        }
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
        var longestSegment: TimedSpeakerSegment?
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
