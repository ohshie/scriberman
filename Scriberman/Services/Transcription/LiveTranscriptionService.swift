import AVFoundation
import CoreML
import FluidAudio
import Foundation
import OSLog

enum LiveTranscriptionError: Error {
    case initializationFailed
}

/// Session identity of one turn-diarizer speaker index within one audio source:
/// clustering-diarizer embeddings accumulate here, and the first confident
/// profile match binds the index for the rest of the session (design D5).
struct SessionSpeakerIdentity {
    private(set) var embeddingSum: [Float] = []
    private(set) var embeddingCount: Int = 0
    var boundProfileID: UUID?
    var boundProfileName: String?

    var isBound: Bool { boundProfileID != nil }

    var averagedEmbedding: [Float] {
        guard embeddingCount > 0 else { return [] }
        return embeddingSum.map { $0 / Float(embeddingCount) }
    }

    mutating func accumulate(_ embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        if embeddingSum.count == embedding.count {
            for index in embedding.indices {
                embeddingSum[index] += embedding[index]
            }
            embeddingCount += 1
        } else {
            embeddingSum = embedding
            embeddingCount = 1
        }
    }
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

/// Speaker-activity frames committed by one streaming turn-diarizer chunk:
/// `[frameCount × numSpeakers]`, frame-major.
struct TurnDiarizerChunk: Sendable {
    let probabilities: [Float]
    let frameCount: Int
}

/// Streaming turn diarizer for one audio source. Implementations are driven only
/// from `LiveTranscriptionService`'s actor isolation, which never awaits inside
/// these calls.
protocol StreamingTurnDiarizing: AnyObject, Sendable {
    var numSpeakers: Int { get }
    var frameSeconds: Float { get }
    /// Buffers 16 kHz mono `samples` and returns the frames committed by every
    /// chunk they complete.
    func feed(_ samples: [Float]) throws -> [TurnDiarizerChunk]
    /// Flushes buffered audio and returns the remaining frames. Later feeds are
    /// ignored until `reset()`.
    func finish() throws -> [TurnDiarizerChunk]
    func reset()
}

// @unchecked: Nemotron3Diarizer is not thread-safe. LiveTranscriptionService's
// actor is its only caller and calls it synchronously.
final class Nemotron3TurnDiarizer: StreamingTurnDiarizing, @unchecked Sendable {
    private let diarizer: Nemotron3Diarizer
    private var isFinished = false

    init(config: Nemotron3Config, models: Nemotron3Models) {
        self.diarizer = Nemotron3Diarizer(config: config, models: models)
    }

    var numSpeakers: Int { diarizer.config.numSpeakers }
    var frameSeconds: Float { diarizer.config.outputFrameSeconds }

    func feed(_ samples: [Float]) throws -> [TurnDiarizerChunk] {
        // Nemotron3Diarizer traps on appendAudio after finishStream; a reentrant
        // process() while stop() is flushing can reach here.
        guard !isFinished else { return [] }
        diarizer.appendAudio(samples)
        return try diarizer.processBufferedAudio().map(Self.chunk)
    }

    func finish() throws -> [TurnDiarizerChunk] {
        guard !isFinished else { return [] }
        isFinished = true
        return try diarizer.finishStream().map(Self.chunk)
    }

    func reset() {
        diarizer.reset()
        isFinished = false
    }

    private static func chunk(_ result: Nemotron3ChunkResult) -> TurnDiarizerChunk {
        TurnDiarizerChunk(probabilities: result.probabilities, frameCount: result.frameCount)
    }
}

/// A transcribed buffer waiting for its source's turn timeline to cover it
/// (nemotron3-live-turns design D5).
private struct PendingAttribution {
    let text: String
    let tokenTimings: [TokenTiming]?
    let start: Float
    let end: Float
    let longestClusterSegment: TimedSpeakerSegment?
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

    // Streaming turn diarization: one session-long diarizer per source
    // (sources have independent sample clocks; a shared instance would
    // interleave unrelated audio and corrupt its timeline).
    private var turnDiarizers: [AudioSource: any StreamingTurnDiarizing] = [:]
    // Committed speaker segments per source, built from the diarizer's output.
    private var turnTimelines: [AudioSource: TurnTimeline] = [:]
    // Session offset (seconds) from which a source's turn timeline is
    // desynchronized after a feed failure; queries at or past this point
    // return no runs so attribution falls back to embeddings.
    private var turnUnreliableFromOffsets: [AudioSource: Float] = [:]
    // Transcribed buffers held until their source's timeline covers them,
    // oldest first (design D5).
    private var pendingAttributions: [AudioSource: [PendingAttribution]] = [:]
    // Sources with a release loop running; keeps emission in order across
    // actor reentrancy.
    private var releasingSources: Set<AudioSource> = []
    // Committed output may end a frame short of the sample clock.
    private static let coverageTolerance: Float = 0.02

    // Dependencies
    private let speakerEmbeddingStore: SpeakerEmbeddingStore?
    private let speakerMatcher = SpeakerMatcher()

    // Model initialization guard (tasks 4.1, 4.2)
    private(set) var isInitialized = false

    // Audio processing constants (task 2.1: 5.0 → 10.0)
    private static let SAMPLE_RATE: Float = 16000
    private static let VAD_CHUNK_SIZE = 4096
    private static let PRE_ROLL_CHUNK_COUNT = 2
    private static let MAX_SPEECH_SAMPLES = 480_000

    // Pipeline configuration (set at start() time, used throughout session)
    private var storedConfig: LiveTranscriptionPipelineSettings = .defaults

    // Chunk accumulation state
    private var audioConverters: [AudioSource: AudioConverter] = [:]
    private var vadStreamStates: [AudioSource: VadStreamState] = [:]
    private var speechAccumulationBuffers: [AudioSource: [Float]] = [:]
    private var speechStartOffsets: [AudioSource: Float] = [:]
    private var recentPreRollChunks: [AudioSource: [[Float]]] = [:]
    private var vadInputRemainders: [AudioSource: [Float]] = [:]
    private var totalSamplesProcessed: [AudioSource: Int] = [:]
    private var lastFinalSegmentEndOffsets: [AudioSource: Float] = [:]
    private var decoderStates: [AudioSource: TdtDecoderState] = [:]
#if DEBUG
    private var processChunkHookForTesting: (@Sendable ([Float], AudioSource, Float) async -> Void)?
    private var asrTranscribeHookForTesting: (@Sendable ([Float], AudioSource, inout TdtDecoderState) async throws -> ASRResult)?
    private var decoderStateFactoryForTesting: (@Sendable (AsrManager) async throws -> TdtDecoderState)?
#endif

    // Authoritative record of all final segments accumulated this session
    private var collectedFinalSegments: [TranscriptSegment] = []

    // Speaker tracking across session — fallback path only. Chunks attributed
    // without a turn timeline (empty/unreliable) record here under the
    // clustering diarizer's session-local ID, preserving pre-turn-diarizer behavior.
    // Key: session-local speaker ID ("speaker_SPEAKER_0" etc.)
    // Value: (embedding, wasMatched, matchedProfileID)
    var sessionSpeakers: [String: (embedding: [Float], wasMatched: Bool, matchedProfileID: UUID?)] = [:]

    // Primary speaker identity: per-source turn-diarizer speaker index → identity
    // record (accumulated embeddings + sticky profile binding).
    private(set) var sessionSpeakerIdentities: [AudioSource: [Int: SessionSpeakerIdentity]] = [:]

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
    func prepare(workspace: Workspace, config: LiveTranscriptionPipelineSettings = .defaults) async {
        guard !isInitialized else {
            logger.info("LiveTranscriptionService already initialized, skipping prepare()")
            return
        }

        logger.info("Pre-warming live transcription models...")
        await prepare(
            workspace: workspace,
            config: config,
            initializeAsr: { workspace in
                let asrConfig = ASRConfig()
                let asr = AsrManager(config: asrConfig)
                let asrDirectory = try ModelPathResolver().modelDirectory(for: .asrParakeetUltra, in: workspace)
                let asrModels = try await AsrModels.load(from: asrDirectory, version: ModelPathResolver.asrModelVersion, encoderComputeUnits: .cpuAndGPU)
                try await asr.loadModels(asrModels)
                return asr
            },
            initializeDiarizer: { workspace, config in
                let diarizerConfig = DiarizerConfig(
                    clusteringThreshold: Float(config.speakerSimilarityThreshold),
                    minSpeechDuration: Float(config.vadMinSpeechDuration),
                    minSilenceGap: Float(config.minSilenceGap)
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
            initializeVad: { workspace, config in
                let vadDirectory = try ModelPathResolver().modelDirectory(for: .vadSilero, in: workspace)
                let vadModelURL = vadDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
                let mlConfig = MLModelConfiguration()
                mlConfig.computeUnits = .cpuAndNeuralEngine
                let mlModel = try await MLModel.load(contentsOf: vadModelURL, configuration: mlConfig)
                let manager = VadManager(config: VadConfig(defaultThreshold: Float(config.vadThreshold)), vadModel: mlModel)
                return (manager, VadManagerStreamProcessor(manager: manager))
            },
            initializeTurnDiarizers: { workspace in
                // One model shared by per-source diarizers, each owning its own
                // streaming state. Safe because this actor serializes every
                // feed/finish call and none of them await (design D3).
                let repoDirectory = try ModelPathResolver().modelDirectory(for: .nemotron3Diarization, in: workspace)
                let config = ModelPathResolver.nemotron3LoadConfig
                let models = try await Nemotron3Models.load(config: config, directory: repoDirectory)
                var diarizers: [AudioSource: any StreamingTurnDiarizing] = [:]
                for source in AudioSource.allCases {
                    diarizers[source] = Nemotron3TurnDiarizer(config: config, models: models)
                }
                return diarizers
            }
        )
    }

    private func prepare(
        workspace: Workspace,
        config: LiveTranscriptionPipelineSettings,
        initializeAsr: @Sendable (Workspace) async throws -> AsrManager,
        initializeDiarizer: @Sendable (Workspace, LiveTranscriptionPipelineSettings) async throws -> DiarizerManager,
        initializeVad: @Sendable (Workspace, LiveTranscriptionPipelineSettings) async throws -> (VadManager, any LiveVADStreamingProcessing),
        initializeTurnDiarizers: @Sendable (Workspace) async throws -> [AudioSource: any StreamingTurnDiarizing]
    ) async {
        storedConfig = config

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
            let mgr = try await initializeDiarizer(workspace, config)
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
            let (manager, processor) = try await initializeVad(workspace, config)
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

        // 4. Initialize turn diarizers (one per audio source)
        do {
            let diarizers = try await initializeTurnDiarizers(workspace)
            installTurnDiarizers(diarizers)
            logger.info("Turn diarizers initialized from workspace models (\(self.turnDiarizers.count) sources)")
        } catch {
            logger.error("Turn diarizer initialization failed during prepare(): \(error). Live transcription unavailable.")
            asrManager = nil
            diarizer = nil
            vadManager = nil
            vadStreamProcessor = nil
            installTurnDiarizers([:])
            return
        }

        isInitialized = true
        logger.info("LiveTranscriptionService pre-warming complete (diarizer available: \(self.diarizer != nil))")
    }

    // MARK: - Lifecycle

    func start(workspace: Workspace, config: LiveTranscriptionPipelineSettings = .defaults) async throws {
        logger.info("Starting live transcription service (Offline Chunking Mode)")

        audioConverters.removeAll()
        vadStreamStates.removeAll()
        speechAccumulationBuffers.removeAll()
        speechStartOffsets.removeAll()
        recentPreRollChunks.removeAll()
        vadInputRemainders.removeAll()
        totalSamplesProcessed.removeAll()
        lastFinalSegmentEndOffsets.removeAll()
        decoderStates.removeAll()
        collectedFinalSegments.removeAll()
        sessionSpeakers.removeAll()
        sessionSpeakerIdentities.removeAll()
        turnUnreliableFromOffsets.removeAll()
        pendingAttributions.removeAll()
        for turnDiarizer in turnDiarizers.values {
            turnDiarizer.reset()
        }
        installTurnDiarizers(turnDiarizers)

        storedConfig = config

        // task 4.2: skip model loading if already initialized by prepare()
        if !isInitialized {
            await prepare(workspace: workspace, config: config)
        }

        guard isInitialized, asrManager != nil, diarizer != nil, vadStreamProcessor != nil else {
            throw LiveTranscriptionError.initializationFailed
        }

        logger.info("LiveTranscriptionService started (diarizer: \(self.diarizer != nil))")
    }

    func stop() async -> [TranscriptSegment] {
        logger.info("Stopping live transcription service")

        // Finish each turn diarizer stream first so its timeline covers all
        // audio before held buffers and the pending speech buffers below are
        // attributed.
        for (source, turnDiarizer) in turnDiarizers where turnUnreliableFromOffsets[source] == nil {
            do {
                let chunks = try turnDiarizer.finish()
                appendTurnChunks(chunks, for: source)
            } catch {
                markTurnDiarizerUnreliable(source: source, error: error)
            }
        }
        for source in turnDiarizers.keys {
            await releasePendingAttributions(for: source)
        }

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
            recentPreRollChunks[source] = []
        }

        // Anything still held (a stream that failed to finish) is attributed
        // with whatever the timeline has, falling back to embeddings.
        for source in Array(pendingAttributions.keys) {
            await releasePendingAttributions(for: source, force: true)
        }

        // Speaker enrollment at session end: turn-diarizer identity records are the
        // primary source; legacy sessionSpeakers covers fallback-attributed
        // chunks (empty/unreliable timeline stretches).
        if let store = speakerEmbeddingStore, !sessionSpeakerIdentities.isEmpty || !sessionSpeakers.isEmpty {
            do {
                let allProfiles = try await store.fetchAllSnapshots()
                let existingCount = allProfiles.count
                var newSpeakerIndex = 0

                // Iterate deterministically: sources then turn-diarizer indices.
                for source in sessionSpeakerIdentities.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                    let records = sessionSpeakerIdentities[source] ?? [:]
                    for speakerIndex in records.keys.sorted() {
                        guard let record = records[speakerIndex] else { continue }

                        if let profileID = record.boundProfileID {
                            try? await store.updateProfile(id: profileID)
                            logger.info("Updated lastSeen for bound speaker \(speakerIndex) (\(source.rawValue))")
                        } else {
                            let embedding = record.averagedEmbedding
                            guard !embedding.isEmpty else { continue }
                            let name = "Speaker \(existingCount + newSpeakerIndex + 1)"
                            newSpeakerIndex += 1
                            try? await store.enrollSpeaker(name: name, embedding: embedding)
                            logger.info("Enrolled new speaker '\(name)' for turn speaker \(speakerIndex) (\(source.rawValue))")
                        }
                    }
                }

                // Sort by session-local ID for deterministic name assignment
                for sessionLocalId in sessionSpeakers.keys.sorted() {
                    guard let info = sessionSpeakers[sessionLocalId] else { continue }

                    if info.wasMatched, let profileID = info.matchedProfileID {
                        try? await store.updateProfile(id: profileID)
                        logger.info("Updated lastSeen for matched speaker \(sessionLocalId)")
                    } else if !info.embedding.isEmpty {
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
        sessionSpeakerIdentities.removeAll()
        audioConverters.removeAll()
        vadStreamStates.removeAll()
        speechAccumulationBuffers.removeAll()
        speechStartOffsets.removeAll()
        recentPreRollChunks.removeAll()
        vadInputRemainders.removeAll()
        totalSamplesProcessed.removeAll()
        lastFinalSegmentEndOffsets.removeAll()
        decoderStates.removeAll()
        asrManager = nil
        diarizer = nil
        vadManager = nil
        vadStreamProcessor = nil
        installTurnDiarizers([:])
        turnUnreliableFromOffsets.removeAll()
        pendingAttributions.removeAll()
        releasingSources.removeAll()
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

            // Feed every resampled sample (silence included, before VAD
            // gating) so the turn timeline stays aligned with the session
            // sample clock used for TranscriptSegment offsets.
            feedTurnDiarizer(resampled, for: source)
            await releasePendingAttributions(for: source)

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
                let vadSegmentationConfig = VadSegmentationConfig(minSpeechDuration: storedConfig.vadMinSpeechDuration)
                let result = try await vadStreamProcessor.processStreamingChunk(
                    chunk,
                    state: streamState,
                    config: vadSegmentationConfig
                )
                vadStreamStates[source] = result.state

                if result.eventKind == LiveVADEventKind.speechStart {
                    let preRollChunks = recentPreRollChunks[source] ?? []
                    let preRollSamples = preRollChunks.flatMap { $0 }
                    let prependedSampleCount = preRollSamples.count
                    let triggerOffset = Float(currentChunkStartSamples) / Self.SAMPLE_RATE
                    let adjustedOffset = max(
                        lastFinalSegmentEndOffsets[source] ?? 0,
                        max(0, triggerOffset - Float(prependedSampleCount) / Self.SAMPLE_RATE)
                    )
                    speechStartOffsets[source] = adjustedOffset
                    speechAccumulationBuffers[source] = preRollSamples
                    recentPreRollChunks[source] = []
                }

                if result.isTriggered {
                    var speechBuffer = speechAccumulationBuffers[source] ?? []
                    speechBuffer.append(contentsOf: chunk)
                    speechAccumulationBuffers[source] = speechBuffer

                    if speechBuffer.count >= Self.MAX_SPEECH_SAMPLES {
                        await flushSpeechBuffer(for: source)
                        speechAccumulationBuffers[source] = []
                        speechStartOffsets[source] = nil
                        recentPreRollChunks[source] = []
                    }
                }

                if result.eventKind == LiveVADEventKind.speechEnd {
                    // When VAD transitions triggered→false before the accumulation block above,
                    // this final chunk was never added to the buffer. Include it now.
                    if !result.isTriggered {
                        var speechBuffer = speechAccumulationBuffers[source] ?? []
                        speechBuffer.append(contentsOf: chunk)
                        speechAccumulationBuffers[source] = speechBuffer
                    }
                    if let buffer = speechAccumulationBuffers[source], !buffer.isEmpty {
                        await flushSpeechBuffer(for: source)
                    }
                    speechAccumulationBuffers[source] = []
                    speechStartOffsets[source] = nil
                    recentPreRollChunks[source] = []
                }

                if !result.isTriggered && result.eventKind != LiveVADEventKind.speechEnd {
                    appendPreRollChunk(chunk, for: source)
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

    // MARK: - Streaming Turn Diarization

    private func installTurnDiarizers(_ diarizers: [AudioSource: any StreamingTurnDiarizing]) {
        turnDiarizers = diarizers
        turnTimelines = diarizers.mapValues {
            TurnTimeline(numSpeakers: $0.numSpeakers, frameSeconds: $0.frameSeconds)
        }
    }

    private func feedTurnDiarizer(_ samples: [Float], for source: AudioSource) {
        guard let turnDiarizer = turnDiarizers[source] else { return }
        // Once desynchronized there is no way to realign the timeline with
        // the sample clock mid-session; stop paying for inference.
        guard turnUnreliableFromOffsets[source] == nil else { return }

        do {
            let chunks = try turnDiarizer.feed(samples)
            appendTurnChunks(chunks, for: source)
        } catch {
            markTurnDiarizerUnreliable(source: source, error: error, fedSampleCount: samples.count)
        }
    }

    private func appendTurnChunks(_ chunks: [TurnDiarizerChunk], for source: AudioSource) {
        guard !chunks.isEmpty, var timeline = turnTimelines[source] else { return }
        for chunk in chunks {
            timeline.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
        }
        turnTimelines[source] = timeline
    }

    private func markTurnDiarizerUnreliable(source: AudioSource, error: Error, fedSampleCount: Int = 0) {
        let failureOffset = turnTimelines[source]?.coveredUntil
            ?? Float((totalSamplesProcessed[source] ?? 0) - fedSampleCount) / Self.SAMPLE_RATE
        turnUnreliableFromOffsets[source] = failureOffset
        logger.error("Turn diarizer failed for \(source.rawValue) at \(String(format: "%.1f", failureOffset))s; attribution falls back to embeddings from here: \(error)")
    }

    /// Speaker runs from the source's committed turn timeline overlapping
    /// `[start, end]` session seconds. Empty when the diarizer is unavailable or
    /// its timeline is unreliable for the range — callers fall back to
    /// embedding-based attribution.
    func turnSpeakerRuns(for source: AudioSource, start: Float, end: Float) -> [SpeakerRun] {
        guard let timeline = turnTimelines[source] else { return [] }
        if let unreliableFrom = turnUnreliableFromOffsets[source], end > unreliableFrom {
            return []
        }
        return LiveSpeakerTimeline.speakerRuns(in: timeline.segments, start: start, end: end)
    }

    /// Dominant turn-diarizer speaker index for `[start, end]`, or nil when the
    /// timeline has no reliable data for the range.
    func dominantTurnSpeaker(for source: AudioSource, start: Float, end: Float) -> Int? {
        guard let timeline = turnTimelines[source] else { return nil }
        if let unreliableFrom = turnUnreliableFromOffsets[source], end > unreliableFrom {
            return nil
        }
        return LiveSpeakerTimeline.dominantSpeaker(in: timeline.segments, start: start, end: end)
    }

    /// Whether a buffer ending at `end` can be attributed now: the timeline
    /// covers it, or there is no timeline worth waiting for.
    private func isTurnTimelineReady(through end: Float, for source: AudioSource) -> Bool {
        guard let timeline = turnTimelines[source] else { return true }
        if let unreliableFrom = turnUnreliableFromOffsets[source], end > unreliableFrom {
            return true
        }
        return timeline.coveredUntil + Self.coverageTolerance >= end
    }

    /// Attributes and emits held buffers, oldest first, while the timeline
    /// covers them (or unconditionally when `force`). One loop per source runs
    /// at a time so emission order survives actor reentrancy.
    private func releasePendingAttributions(for source: AudioSource, force: Bool = false) async {
        guard !releasingSources.contains(source) else { return }
        releasingSources.insert(source)
        defer { releasingSources.remove(source) }

        while let next = pendingAttributions[source]?.first,
              force || isTurnTimelineReady(through: next.end, for: source) {
            pendingAttributions[source]?.removeFirst()
            await attribute(next, source: source)
        }
    }

    private func flushSpeechBuffer(for source: AudioSource) async {
        guard let samples = speechAccumulationBuffers[source], !samples.isEmpty else {
            return
        }

        let amplitudeGate = storedConfig.asrAmplitudeGate
        if amplitudeGate > 0.0 {
            let peakAmplitude = samples.map { abs($0) }.max() ?? 0.0
            if peakAmplitude < Float(amplitudeGate) {
                logger.debug("🔇 Near-silent buffer discarded (peak: \(String(format: "%.6f", peakAmplitude)) < gate: \(String(format: "%.6f", amplitudeGate)))")
                return
            }
        }

        let capturedSamples = samples
        let capturedOffset = speechStartOffsets[source]
            ?? max(0, currentSessionOffset(for: source) - Float(samples.count) / Self.SAMPLE_RATE)

        // Clear before awaiting so a reentrant stop() call sees an empty buffer
        // and does not transcribe the same audio a second time.
        speechAccumulationBuffers[source] = []
        speechStartOffsets[source] = nil
        recentPreRollChunks[source] = []

        await processChunk(samples: capturedSamples, source: source, currentOffset: capturedOffset)
    }

    private func appendPreRollChunk(_ chunk: [Float], for source: AudioSource) {
        var chunks = recentPreRollChunks[source] ?? []
        chunks.append(chunk)
        if chunks.count > Self.PRE_ROLL_CHUNK_COUNT {
            chunks.removeFirst(chunks.count - Self.PRE_ROLL_CHUNK_COUNT)
        }
        recentPreRollChunks[source] = chunks
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

            var decoderState: TdtDecoderState
            do {
                decoderState = try await decoderStateForSource(source, asrManager: asrManager)
            } catch {
                logger.error("Failed to create/reuse decoder state for \(source.rawValue): \(error). Falling back to fresh state for this chunk.")
                decoderStates[source] = nil
                decoderState = try TdtDecoderState()
            }

#if DEBUG
            let asrResult: ASRResult
            if let asrTranscribeHookForTesting {
                asrResult = try await asrTranscribeHookForTesting(samples, source, &decoderState)
            } else {
                asrResult = try await asrManager.transcribe(samples, decoderState: &decoderState)
            }
#else
            let asrResult = try await asrManager.transcribe(samples, decoderState: &decoderState)
#endif
            decoderStates[source] = decoderState

            let confidenceGate = storedConfig.asrConfidenceGate
            if confidenceGate > 0.0, asrResult.confidence < Float(confidenceGate) {
                logger.info("🚫 Low-confidence result discarded (confidence: \(String(format: "%.3f", asrResult.confidence)) < gate: \(String(format: "%.3f", confidenceGate)))")
                return
            }

            let cleanedText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !cleanedText.isEmpty else {
                logger.info("⚠️ TRANSCRIPTION RETURNED EMPTY - ASR failed to detect speech")
                return
            }

            // Clustering diarization is retained solely for embedding
            // extraction (design D1): the turn diarizer provides turn boundaries and
            // within-session consistency; embeddings provide identity.
            var longestClusterSegment: TimedSpeakerSegment?
            if let diarizer = diarizer {
                do {
                    let diarizationResult = try diarizer.performCompleteDiarization(samples, sampleRate: 16000)
                    longestClusterSegment = findLongestSpeaker(from: diarizationResult)
                } catch {
                    logger.error("Embedding diarization failed: \(error)")
                }
            }

            pendingAttributions[source, default: []].append(PendingAttribution(
                text: cleanedText,
                tokenTimings: asrResult.tokenTimings,
                start: currentOffset,
                end: currentOffset + chunkDuration,
                longestClusterSegment: longestClusterSegment
            ))
            await releasePendingAttributions(for: source)

        } catch {
            logger.error("Chunk processing failed: \(error)")
        }
    }

    /// Splits a covered buffer at turn boundaries and emits its segments, or
    /// falls back to embedding attribution when the timeline has nothing.
    private func attribute(_ pending: PendingAttribution, source: AudioSource) async {
        let bufferStart = pending.start
        let bufferEnd = pending.end
        let cleanedText = pending.text
        let longestClusterSegment = pending.longestClusterSegment
        let chunkEmbedding = longestClusterSegment?.embedding ?? []
        let runs = turnSpeakerRuns(for: source, start: bufferStart, end: bufferEnd)
        let parts = LiveSegmentSplitter.planParts(runs: runs, start: bufferStart, end: bufferEnd)

        guard !parts.isEmpty else {
            // Timeline has no reliable data for this range: fall back to
            // embedding-based attribution (pre-turn-diarizer behavior).
            let speakerID = await fallbackSpeakerID(from: longestClusterSegment)
            logger.info("📝 RESULT [\(source.rawValue)] (embedding fallback): \(speakerID): \(cleanedText)")
            emitFinalSegment(speakerId: speakerID, text: cleanedText, start: bufferStart, end: bufferEnd, source: source)
            return
        }

        // Accumulate the chunk's embedding on the dominant part's
        // identity record; first confident match binds the turn-diarizer index
        // to a profile for the rest of the session (design D5).
        if !chunkEmbedding.isEmpty,
           let dominantPart = parts.max(by: { $0.duration < $1.duration }) {
            var record = sessionSpeakerIdentities[source]?[dominantPart.speakerIndex] ?? SessionSpeakerIdentity()
            record.accumulate(chunkEmbedding)
            if !record.isBound, let match = await findBestSpeakerMatch(for: chunkEmbedding) {
                record.boundProfileID = match.id
                record.boundProfileName = match.name
                logger.info("📍 Bound turn speaker \(dominantPart.speakerIndex) (\(source.rawValue)) to profile '\(match.name)'")
            }
            sessionSpeakerIdentities[source, default: [:]][dominantPart.speakerIndex] = record
        }

        let texts = LiveSegmentSplitter.apportionText(
            cleanedText,
            parts: parts,
            bufferStart: bufferStart,
            tokenTimings: pending.tokenTimings
        )

        for (part, text) in zip(parts, texts) where !text.isEmpty {
            let speakerID = turnSpeakerLabel(for: part.speakerIndex, source: source)
            logger.info("📝 RESULT [\(source.rawValue)]: \(speakerID): \(text)")
            emitFinalSegment(speakerId: speakerID, text: text, start: part.start, end: part.end, source: source)
        }
    }

    /// Label for a turn-diarizer speaker index: the bound profile's name, or a
    /// session-local ID that stays stable for the whole session.
    private func turnSpeakerLabel(for speakerIndex: Int, source: AudioSource) -> String {
        if let name = sessionSpeakerIdentities[source]?[speakerIndex]?.boundProfileName {
            return name
        }
        return "speaker_\(source.rawValue)_\(speakerIndex)"
    }

    /// Pre-turn-diarizer attribution used when the timeline has no data for a
    /// buffer: match the chunk's embedding against stored profiles and track
    /// the result in `sessionSpeakers` for enrollment at stop().
    private func fallbackSpeakerID(from longestSegment: TimedSpeakerSegment?) async -> String {
        guard let longestSegment else {
            logger.info("📍 No speaker detected in audio chunk")
            return "unknown"
        }

        let sessionLocalId = "speaker_\(longestSegment.speakerId)"
        let embedding = longestSegment.embedding

        if let match = await findBestSpeakerMatch(for: embedding) {
            sessionSpeakers[sessionLocalId] = (
                embedding: embedding,
                wasMatched: true,
                matchedProfileID: match.id
            )
            logger.info("📍 Matched speaker: \(match.name) (profile match)")
            return match.name
        }

        if sessionSpeakers[sessionLocalId] == nil && !embedding.isEmpty {
            sessionSpeakers[sessionLocalId] = (
                embedding: embedding,
                wasMatched: false,
                matchedProfileID: nil
            )
        }
        logger.info("📍 New/unmatched speaker: \(sessionLocalId)")
        return sessionLocalId
    }

    private func emitFinalSegment(speakerId: String, text: String, start: Float, end: Float, source: AudioSource) {
        // Sanitize at the choke point so every emit path (turn-split parts,
        // single-part, embedding fallback, stop() flush) is covered (design D1).
        guard let sanitizedText = LiveSegmentSanitizer.sanitize(text) else {
            logger.info("🧹 Dropped punctuation-only segment [\(source.rawValue)]: \"\(text)\"")
            return
        }
        // User cleanup rules run after built-in sanitization (design D4);
        // a segment emptied by the rules is dropped the same way.
        guard let cleanedText = TranscriptCleanupEngine.apply(storedConfig.cleanupRules, to: sanitizedText) else {
            logger.info("🧹 Dropped segment emptied by cleanup rules [\(source.rawValue)]: \"\(sanitizedText)\"")
            return
        }
        let segment = TranscriptSegment(
            speakerId: speakerId,
            text: cleanedText,
            startTime: start,
            endTime: end,
            audioSource: source,
            isFinal: true
        )
        collectedFinalSegments.append(segment)
        lastFinalSegmentEndOffsets[source] = segment.endTime
        resultsTuple.continuation.yield(segment)
    }

    private func decoderStateForSource(_ source: AudioSource, asrManager: AsrManager) async throws -> TdtDecoderState {
        if let decoderState = decoderStates[source] {
            return decoderState
        }

#if DEBUG
        if let decoderStateFactoryForTesting {
            return try await decoderStateFactoryForTesting(asrManager)
        }
#endif

        let decoderLayers = await asrManager.decoderLayerCount
        return try TdtDecoderState(decoderLayers: decoderLayers)
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
        config: LiveTranscriptionPipelineSettings = .defaults,
        initializeAsr: @Sendable (Workspace) async throws -> AsrManager,
        initializeDiarizer: @Sendable (Workspace, LiveTranscriptionPipelineSettings) async throws -> DiarizerManager,
        initializeVad: @Sendable (Workspace, LiveTranscriptionPipelineSettings) async throws -> (VadManager, any LiveVADStreamingProcessing),
        initializeTurnDiarizers: @Sendable (Workspace) async throws -> [AudioSource: any StreamingTurnDiarizing] = { _ in [:] }
    ) async {
        await prepare(
            workspace: workspace,
            config: config,
            initializeAsr: initializeAsr,
            initializeDiarizer: initializeDiarizer,
            initializeVad: initializeVad,
            initializeTurnDiarizers: initializeTurnDiarizers
        )
    }

    func setTurnDiarizersForTesting(_ diarizers: [AudioSource: any StreamingTurnDiarizing]) {
        installTurnDiarizers(diarizers)
    }

    func pendingAttributionCountForTesting(source: AudioSource) -> Int {
        pendingAttributions[source]?.count ?? 0
    }

    func injectSpeakerIdentityForTesting(source: AudioSource, speakerIndex: Int, identity: SessionSpeakerIdentity) {
        sessionSpeakerIdentities[source, default: [:]][speakerIndex] = identity
    }

    func speakerIdentityForTesting(source: AudioSource, speakerIndex: Int) -> SessionSpeakerIdentity? {
        sessionSpeakerIdentities[source]?[speakerIndex]
    }

    func markTurnDiarizerUnreliableForTesting(source: AudioSource, fromOffset: Float) {
        self.turnUnreliableFromOffsets[source] = fromOffset
    }

    func lastFinalSegmentEndOffsetForTesting(source: AudioSource) -> Float? {
        lastFinalSegmentEndOffsets[source]
    }

    func setVADProcessorForTesting(_ processor: any LiveVADStreamingProcessing) {
        self.vadStreamProcessor = processor
    }

    func setProcessChunkHookForTesting(_ hook: @escaping @Sendable ([Float], AudioSource, Float) async -> Void) {
        self.processChunkHookForTesting = hook
    }

    func setStoredConfigForTesting(_ config: LiveTranscriptionPipelineSettings) {
        self.storedConfig = config
    }

    func setAsrManagerForTesting(_ manager: AsrManager) {
        self.asrManager = manager
    }

    func setAsrTranscribeHookForTesting(_ hook: @escaping @Sendable ([Float], AudioSource, inout TdtDecoderState) async throws -> ASRResult) {
        self.asrTranscribeHookForTesting = hook
    }

    func setDecoderStateFactoryForTesting(_ factory: @escaping @Sendable (AsrManager) async throws -> TdtDecoderState) {
        self.decoderStateFactoryForTesting = factory
    }
}
#endif
