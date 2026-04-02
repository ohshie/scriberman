import AVFoundation
import CoreML
import FluidAudio
import Foundation
import OSLog

enum LiveTranscriptionError: Error {
    case initializationFailed
}

enum LiveVADEventKind {
    case speechStart
    case speechEnd
}

struct LiveVADProcessingResult {
    let state: VadStreamState
    let isTriggered: Bool
    let eventKind: LiveVADEventKind?
}

protocol LiveVADStreamingProcessing: Sendable {
    func processStreamingChunk(
        _ chunk: [Float],
        state: VadStreamState,
        config: VadSegmentationConfig
    ) async throws -> LiveVADProcessingResult
}

private struct VadManagerStreamProcessor: LiveVADStreamingProcessing {
    let manager: VadManager

    func processStreamingChunk(
        _ chunk: [Float],
        state: VadStreamState,
        config: VadSegmentationConfig
    ) async throws -> LiveVADProcessingResult {
        let result = try await manager.processStreamingChunk(chunk, state: state, config: config)
        let mappedEvent: LiveVADEventKind?
        if result.event?.kind == .speechStart {
            mappedEvent = .speechStart
        } else if result.event?.kind == .speechEnd {
            mappedEvent = .speechEnd
        } else {
            mappedEvent = nil
        }
        return LiveVADProcessingResult(
            state: result.state,
            isTriggered: result.state.triggered,
            eventKind: mappedEvent
        )
    }
}

actor LiveTranscriptionService {
    private let logger = Logger(subsystem: "Scriberman", category: "LiveTranscriptionService")
    private let fileManager = FileManager.default
    private let modelPathResolver = ModelPathResolver()

    // Core managers
    private var asrManager: AsrManager?
    private var diarizer: DiarizerManager?
    private var vadManager: VadManager?
    private var vadStreamProcessor: (any LiveVADStreamingProcessing)?

    // Dependencies
    private let speakerEmbeddingStore: SpeakerEmbeddingStore?
    private let speakerMatcher = SpeakerMatcher()

    // Model initialization guard (tasks 4.1, 4.2)
    private(set) var isInitialized = false

    // Audio processing constants (task 2.1: 5.0 → 10.0)
    private static let SAMPLE_RATE: Float = 16000
    private static let VAD_CHUNK_SIZE = 4096
    private static let MAX_SPEECH_SAMPLES = 480_000

    // Chunk accumulation state
    private var audioConverters: [AudioSource: AudioConverter] = [:]
    private var vadStreamStates: [AudioSource: VadStreamState] = [:]
    private var speechAccumulationBuffers: [AudioSource: [Float]] = [:]
    private var speechStartOffsets: [AudioSource: Float] = [:]
    private var vadInputRemainders: [AudioSource: [Float]] = [:]
    private var totalSamplesProcessed: [AudioSource: Int] = [:]
#if DEBUG
    private var processChunkHookForTesting: (@Sendable ([Float], AudioSource, Float) async -> Void)?
#endif

    // Authoritative record of all final segments accumulated this session
    private var collectedFinalSegments: [TranscriptSegment] = []

    // Speaker tracking across session (task 3.4)
    // Key: session-local speaker ID ("speaker_SPEAKER_0" etc.)
    // Value: (embedding, wasMatched, matchedProfileID)
    var sessionSpeakers: [String: (embedding: [Float], wasMatched: Bool, matchedProfileID: UUID?)] = [:]

    private let resultsTuple: (stream: AsyncStream<TranscriptSegment>, continuation: AsyncStream<TranscriptSegment>.Continuation)

    var transcriptStream: AsyncStream<TranscriptSegment> {
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
        await prepare(
            workspace: workspace,
            initializeAsr: { workspace in
                let asrConfig = ASRConfig()
                let asr = AsrManager(config: asrConfig)
                let asrDirectory = try ModelPathResolver().modelDirectory(for: .asrParakeetV3, in: workspace)
                let asrModels = try await AsrModels.load(from: asrDirectory)
                try await asr.initialize(models: asrModels)
                return asr
            },
            initializeDiarizer: { workspace in
                let diarizerConfig = DiarizerConfig(
                    clusteringThreshold: 0.5,
                    minSpeechDuration: 0.5,
                    minSilenceGap: 0.2
                )
                let mgr = DiarizerManager(config: diarizerConfig)
                let diarizerRepo = try ModelPathResolver().modelDirectory(for: .offlineDiarization, in: workspace)
                let segmentationURL = diarizerRepo.appendingPathComponent("pyannote_segmentation.mlmodelc", isDirectory: true)
                let embeddingURL = diarizerRepo.appendingPathComponent("wespeaker_v2.mlmodelc", isDirectory: true)
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: segmentationURL.path),
                      fileManager.fileExists(atPath: embeddingURL.path)
                else {
                    throw LiveTranscriptionError.initializationFailed
                }

                let models = try await DiarizerModels.load(
                    localSegmentationModel: segmentationURL,
                    localEmbeddingModel: embeddingURL
                )
                mgr.initialize(models: models)
                return mgr
            },
            initializeVad: { workspace in
                let vadDirectory = try ModelPathResolver().modelDirectory(for: .vadSilero, in: workspace)
                let vadModelURL = vadDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
                let mlConfig = MLModelConfiguration()
                mlConfig.computeUnits = .cpuAndNeuralEngine
                let mlModel = try await MLModel.load(contentsOf: vadModelURL, configuration: mlConfig)
                let manager = VadManager(config: VadConfig(defaultThreshold: 0.75), vadModel: mlModel)
                return (manager, VadManagerStreamProcessor(manager: manager))
            }
        )
    }

    private func prepare(
        workspace: Workspace,
        initializeAsr: @Sendable (Workspace) async throws -> AsrManager,
        initializeDiarizer: @Sendable (Workspace) async throws -> DiarizerManager,
        initializeVad: @Sendable (Workspace) async throws -> (VadManager, any LiveVADStreamingProcessing)
    ) async {
        // 1. Initialize ASR
        do {
            let asr = try await initializeAsr(workspace)
            self.asrManager = asr
            logger.info("AsrManager initialized")
        } catch {
            logger.error("ASR initialization failed during prepare(): \(error). Live transcription unavailable.")
            // Leave isInitialized = false so start() can surface the error
            asrManager = nil
            diarizer = nil
            vadManager = nil
            vadStreamProcessor = nil
            return
        }

        // 2. Initialize DiarizerManager
        do {
            let mgr = try await initializeDiarizer(workspace)
            self.diarizer = mgr
            logger.info("DiarizerManager initialized from workspace models")
        } catch {
            logger.error("Diarizer initialization failed during prepare(): \(error). Live transcription unavailable.")
            asrManager = nil
            diarizer = nil
            vadManager = nil
            vadStreamProcessor = nil
            return
        }

        // 3. Initialize VAD
        do {
            let (manager, processor) = try await initializeVad(workspace)
            self.vadManager = manager
            self.vadStreamProcessor = processor
            logger.info("VadManager initialized from workspace models")
        } catch {
            logger.error("VAD initialization failed during prepare(): \(error). Live transcription unavailable.")
            asrManager = nil
            diarizer = nil
            vadManager = nil
            vadStreamProcessor = nil
            return
        }

        isInitialized = true
        logger.info("LiveTranscriptionService pre-warming complete (diarizer available: \(self.diarizer != nil))")
    }

    // MARK: - Lifecycle

    func start(workspace: Workspace) async throws {
        logger.info("Starting live transcription service (Offline Chunking Mode)")

        audioConverters.removeAll()
        vadStreamStates.removeAll()
        speechAccumulationBuffers.removeAll()
        speechStartOffsets.removeAll()
        vadInputRemainders.removeAll()
        totalSamplesProcessed.removeAll()
        collectedFinalSegments.removeAll()
        sessionSpeakers.removeAll()

        // task 4.2: skip model loading if already initialized by prepare()
        if !isInitialized {
            await prepare(workspace: workspace)
        }

        guard isInitialized, asrManager != nil, diarizer != nil, vadStreamProcessor != nil else {
            throw LiveTranscriptionError.initializationFailed
        }

        logger.info("LiveTranscriptionService started (diarizer: \(self.diarizer != nil))")
    }

    func stop() async -> [TranscriptSegment] {
        logger.info("Stopping live transcription service")

        // Flush pending speech buffers before speaker enrollment.
        for source in speechAccumulationBuffers.keys {
            guard let pendingSamples = speechAccumulationBuffers[source], !pendingSamples.isEmpty else {
                continue
            }

            let fallbackStartOffset = max(
                0,
                currentSessionOffset(for: source) - Float(pendingSamples.count) / Self.SAMPLE_RATE
            )
            if speechStartOffsets[source] == nil {
                speechStartOffsets[source] = fallbackStartOffset
            }

            await flushSpeechBuffer(for: source)
            speechAccumulationBuffers[source] = []
            speechStartOffsets[source] = nil
        }

        // tasks 3.5, 3.6: Speaker enrollment at session end
        if let store = speakerEmbeddingStore, !sessionSpeakers.isEmpty {
            do {
                let allProfiles = try await store.fetchAllSnapshots()
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
        audioConverters.removeAll()
        vadStreamStates.removeAll()
        speechAccumulationBuffers.removeAll()
        speechStartOffsets.removeAll()
        vadInputRemainders.removeAll()
        totalSamplesProcessed.removeAll()
        asrManager = nil
        diarizer = nil
        vadManager = nil
        vadStreamProcessor = nil
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
            totalSamplesProcessed[source] = (totalSamplesProcessed[source] ?? 0) + resampled.count

            var combinedSamples = vadInputRemainders[source] ?? []
            combinedSamples.append(contentsOf: resampled)

            let chunkSize = Self.VAD_CHUNK_SIZE
            let processableCount = (combinedSamples.count / chunkSize) * chunkSize
            let remainderCount = combinedSamples.count - processableCount

            if remainderCount > 0 {
                vadInputRemainders[source] = Array(combinedSamples.suffix(remainderCount))
            } else {
                vadInputRemainders[source] = []
            }

            guard processableCount > 0 else { return }
            guard let vadStreamProcessor else { return }

            let processableSamples = Array(combinedSamples.prefix(processableCount))
            var currentChunkStartSamples = (totalSamplesProcessed[source] ?? 0) - processableCount

            for startIndex in stride(from: 0, to: processableCount, by: chunkSize) {
                let chunk = Array(processableSamples[startIndex..<(startIndex + chunkSize)])
                let streamState = vadStreamStates[source] ?? .initial()
                let result = try await vadStreamProcessor.processStreamingChunk(
                    chunk,
                    state: streamState,
                    config: VadSegmentationConfig.default
                )
                vadStreamStates[source] = result.state

                if result.eventKind == LiveVADEventKind.speechStart {
                    speechStartOffsets[source] = Float(currentChunkStartSamples) / Self.SAMPLE_RATE
                    if speechAccumulationBuffers[source] == nil {
                        speechAccumulationBuffers[source] = []
                    }
                }

                if result.isTriggered {
                    var speechBuffer = speechAccumulationBuffers[source] ?? []
                    speechBuffer.append(contentsOf: chunk)
                    speechAccumulationBuffers[source] = speechBuffer

                    if speechBuffer.count >= Self.MAX_SPEECH_SAMPLES {
                        await flushSpeechBuffer(for: source)
                        speechAccumulationBuffers[source] = []
                        speechStartOffsets[source] = nil
                    }
                }

                if result.eventKind == LiveVADEventKind.speechEnd {
                    if let buffer = speechAccumulationBuffers[source], !buffer.isEmpty {
                        await flushSpeechBuffer(for: source)
                    }
                    speechAccumulationBuffers[source] = []
                    speechStartOffsets[source] = nil
                }

                currentChunkStartSamples += chunkSize
            }
        } catch {
            logger.error("Error processing live audio (\(source.rawValue)): \(error.localizedDescription)")
        }
    }

    private func currentSessionOffset(for source: AudioSource) -> Float {
        Float(totalSamplesProcessed[source] ?? 0) / Self.SAMPLE_RATE
    }

    private func flushSpeechBuffer(for source: AudioSource) async {
        guard let samples = speechAccumulationBuffers[source], !samples.isEmpty else {
            return
        }

        let startOffset = speechStartOffsets[source]
            ?? max(0, currentSessionOffset(for: source) - Float(samples.count) / Self.SAMPLE_RATE)
        await processChunk(samples: samples, source: source, currentOffset: startOffset)
    }

    private func processChunk(samples: [Float], source: AudioSource, currentOffset: Float) async {
#if DEBUG
        if let processChunkHookForTesting {
            await processChunkHookForTesting(samples, source, currentOffset)
            return
        }
#endif
        guard let asrManager = asrManager else { return }

        let chunkDuration = Float(samples.count) / Self.SAMPLE_RATE

        do {
            let maxAmplitude = samples.map { abs($0) }.max() ?? 0.0

            logger.info("🎤 Transcribing \(source.rawValue) chunk (\(samples.count) samples = \(String(format: "%.1f", chunkDuration))s, max amplitude: \(String(format: "%.6f", maxAmplitude)))...")

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

                        if let match = await findBestSpeakerMatch(for: embedding) {
                            speakerID = match.name
                            sessionSpeakers[sessionLocalId] = (
                                embedding: embedding,
                                wasMatched: true,
                                matchedProfileID: match.id
                            )
                            logger.info("📍 Matched speaker: \(speakerID) (profile match, \(String(format: "%.1f", duration))s)")
                        } else {
                            speakerID = sessionLocalId
                            if sessionSpeakers[sessionLocalId] == nil && !embedding.isEmpty {
                                sessionSpeakers[sessionLocalId] = (
                                    embedding: embedding,
                                    wasMatched: false,
                                    matchedProfileID: nil
                                )
                            }
                            logger.info("📍 New/unmatched speaker: \(speakerID) (\(String(format: "%.1f", duration))s)")
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

    private func findBestSpeakerMatch(for embedding: [Float]) async -> SpeakerProfileSnapshot? {
        guard !embedding.isEmpty, let store = speakerEmbeddingStore else {
            return nil
        }

        // Keep using the store-level fast path when available.
        if let match = await store.findBestMatchSnapshot(
            embedding: embedding,
            threshold: 1.0 - speakerMatcher.threshold
        ) {
            return match
        }

        guard let profiles = try? await store.fetchAllSnapshots() else {
            return nil
        }
        return speakerMatcher.findBestMatch(for: embedding, in: profiles)
    }
}

#if DEBUG
extension LiveTranscriptionService {
    func prepareForTesting(
        workspace: Workspace,
        initializeAsr: @Sendable (Workspace) async throws -> AsrManager,
        initializeDiarizer: @Sendable (Workspace) async throws -> DiarizerManager,
        initializeVad: @Sendable (Workspace) async throws -> (VadManager, any LiveVADStreamingProcessing)
    ) async {
        await prepare(
            workspace: workspace,
            initializeAsr: initializeAsr,
            initializeDiarizer: initializeDiarizer,
            initializeVad: initializeVad
        )
    }

    func setVADProcessorForTesting(_ processor: any LiveVADStreamingProcessing) {
        self.vadStreamProcessor = processor
    }

    func setProcessChunkHookForTesting(_ hook: @escaping @Sendable ([Float], AudioSource, Float) async -> Void) {
        self.processChunkHookForTesting = hook
    }
}
#endif
