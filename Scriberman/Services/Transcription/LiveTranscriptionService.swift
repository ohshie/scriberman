import AVFoundation
import CoreML
import FluidAudio
import Foundation
import OSLog

enum LiveTranscriptionError: Error {
    case initializationFailed
}

/// The session identity a live segment belongs to. The source and the identity type are part of
/// the reference, so a turn-diarizer speaker and a clustering speaker, or the same index on two
/// sources, never share one.
enum LiveSpeakerReference: Hashable, Sendable {
    /// A turn-diarizer speaker index of one source.
    case turn(AudioSource, Int)
    /// A clustering-diarizer speaker of one source, used when the turn timeline has no data.
    case fallback(AudioSource, String)

    var source: AudioSource {
        switch self {
        case let .turn(source, _), let .fallback(source, _):
            return source
        }
    }

    /// The speaker ID used while the identity matches no profile.
    var sessionLocalID: String {
        switch self {
        case let .turn(source, index):
            return "speaker_\(source.rawValue)_\(index)"
        case let .fallback(source, clusteringID):
            return "speaker_\(source.rawValue)_cluster_\(clusteringID)"
        }
    }
}

/// One live speaker identity: clustering-diarizer embeddings accumulate here, weighted by the
/// seconds of speech each came from, and the identity's current profile match. The match is
/// re-evaluated as the voiceprint grows (design D4).
struct SessionSpeakerIdentity {
    /// Clustering segments shorter than this give no embedding.
    static let minimumEmbeddingSeconds: Float = 1.0
    /// An identity is matched only once it has this much qualifying speech.
    static let minimumMatchingSeconds: Float = 3.0

    private(set) var embeddingSum: [Float] = []
    private(set) var speechSeconds: Float = 0
    var boundProfileID: UUID?
    var boundProfileName: String?

    var isBound: Bool { boundProfileID != nil }

    /// The duration-weighted mean of the accumulated embeddings.
    var averagedEmbedding: [Float] {
        guard speechSeconds > 0 else { return [] }
        return embeddingSum.map { $0 / speechSeconds }
    }

    /// Whether the identity has enough speech to be matched or saved with a voiceprint.
    var hasMatchableVoiceprint: Bool {
        speechSeconds >= Self.minimumMatchingSeconds && !embeddingSum.isEmpty
    }

    mutating func accumulate(_ embedding: [Float], seconds: Float) {
        guard !embedding.isEmpty, seconds > 0 else { return }
        if embeddingSum.count == embedding.count {
            for index in embedding.indices {
                embeddingSum[index] += embedding[index] * seconds
            }
            speechSeconds += seconds
        } else {
            embeddingSum = embedding.map { $0 * seconds }
            speechSeconds = seconds
        }
    }
}

/// What a stopped live session hands back for saving.
struct LiveSessionResult: Sendable {
    /// Final segments, already carrying their final speaker IDs.
    var segments: [TranscriptSegment]
    /// Segment ID → final speaker ID, for every segment emitted for a speaker identity. Segments
    /// persisted during recording are relabelled by ID from this, never by name (design D4).
    var finalSpeakerIDs: [UUID: String] = [:]
    /// Voiceprint per final speaker ID, in `VoiceprintSpace.current`.
    var speakerEmbeddings: [String: [Float]] = [:]
}

extension TranscriptSegment {
    /// This segment with its speaker ID replaced by `finalSpeakerIDs[id]`, keeping its identity.
    func relabelled(using finalSpeakerIDs: [UUID: String]) -> TranscriptSegment {
        guard let speakerId = finalSpeakerIDs[id], speakerId != self.speakerId else { return self }
        return TranscriptSegment(
            id: id,
            speakerId: speakerId,
            text: text,
            startTime: startTime,
            endTime: endTime,
            audioSource: audioSource,
            isFinal: isFinal
        )
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
    /// Every clustering-diarizer segment of the chunk, chunk-relative.
    let clusterSegments: [TimedSpeakerSegment]
}

/// Settings that shape how models are constructed (`VadConfig`,
/// `VadSegmentationConfig`, `DiarizerConfig`). A change starts a new
/// preparation (design D3).
struct LiveConstructionSettings: Hashable, Sendable {
    let vadThreshold: Double
    let vadMinSpeechDuration: Double
    let speakerSimilarityThreshold: Double
    let minSilenceGap: Double

    init(_ settings: LiveTranscriptionPipelineSettings) {
        vadThreshold = settings.vadThreshold
        vadMinSpeechDuration = settings.vadMinSpeechDuration
        speakerSimilarityThreshold = settings.speakerSimilarityThreshold
        minSilenceGap = settings.minSilenceGap
    }
}

struct LivePreparationKey: Hashable, Sendable {
    let workspaceRoot: URL
    let modelRevision: String
    let construction: LiveConstructionSettings
    let processor: AsrProcessor
}

/// Loaded models from one preparation. The factories build the stateful
/// per-recording objects in `start` (design D3).
struct LivePreparedModels: Sendable {
    let asrManager: AsrManager
    let vadProcessor: any LiveVADStreamingProcessing
    let makeDiarizer: @Sendable () -> DiarizerManager
    let makeTurnDiarizers: @Sendable () -> [AudioSource: any StreamingTurnDiarizing]
}

/// Model loading steps used by a preparation. Tests inject their own.
struct LiveModelLoader: Sendable {
    var loadAsr: @Sendable (Workspace, AsrProcessor) async throws -> AsrManager
    var loadDiarizer: @Sendable (Workspace, LiveConstructionSettings) async throws -> @Sendable () -> DiarizerManager
    var loadVad: @Sendable (Workspace, LiveConstructionSettings) async throws -> any LiveVADStreamingProcessing
    var loadTurnDiarizers: @Sendable (Workspace) async throws -> @Sendable () -> [AudioSource: any StreamingTurnDiarizing]

    static let workspace = LiveModelLoader(
        loadAsr: { workspace, processor in
            let asr = AsrManager(config: ASRConfig())
            let asrDirectory = try ModelPathResolver().modelDirectory(for: .asrParakeetUltra, in: workspace)
            let asrModels = try await AsrModels.load(
                from: asrDirectory,
                version: ModelPathResolver.asrModelVersion,
                encoderComputeUnits: processor.encoderComputeUnits
            )
            try await asr.loadModels(asrModels)
            return asr
        },
        loadDiarizer: { workspace, construction in
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
            let diarizerConfig = DiarizerConfig(
                clusteringThreshold: Float(construction.speakerSimilarityThreshold),
                // Embeddings from shorter speech are too noisy to identify a voice (design D4).
                minSpeechDuration: SessionSpeakerIdentity.minimumEmbeddingSeconds,
                minSilenceGap: Float(construction.minSilenceGap)
            )
            // DiarizerManager accumulates speakers across calls, so each
            // recording gets a new one.
            return {
                let manager = DiarizerManager(config: diarizerConfig)
                manager.initialize(models: models)
                return manager
            }
        },
        loadVad: { workspace, construction in
            let vadDirectory = try ModelPathResolver().modelDirectory(for: .vadSilero, in: workspace)
            let vadModelURL = vadDirectory.appendingPathComponent(ModelNames.VAD.sileroVadFile, isDirectory: true)
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .cpuAndNeuralEngine
            let mlModel = try await MLModel.load(contentsOf: vadModelURL, configuration: mlConfig)
            let manager = VadManager(config: VadConfig(defaultThreshold: Float(construction.vadThreshold)), vadModel: mlModel)
            return VadManagerStreamProcessor(manager: manager)
        },
        loadTurnDiarizers: { workspace in
            let repoDirectory = try ModelPathResolver().modelDirectory(for: .nemotron3Diarization, in: workspace)
            let config = ModelPathResolver.nemotron3LoadConfig
            let models = SharedNemotron3Models(try await Nemotron3Models.load(config: config, directory: repoDirectory))
            // One model shared by per-source diarizers, each owning its own
            // streaming state.
            return {
                var diarizers: [AudioSource: any StreamingTurnDiarizing] = [:]
                for source in AudioSource.allCases {
                    diarizers[source] = Nemotron3TurnDiarizer(config: config, models: models.value)
                }
                return diarizers
            }
        }
    )
}

// @unchecked: Nemotron3Models holds reused scratch buffers. Only diarizers
// driven by LiveTranscriptionService's actor use it, and the actor serializes
// every feed/finish call without awaiting inside them.
private final class SharedNemotron3Models: @unchecked Sendable {
    let value: Nemotron3Models

    init(_ value: Nemotron3Models) {
        self.value = value
    }
}

protocol LiveTranscribing: Sendable {
    func prepare(workspace: Workspace, config: LiveTranscriptionPipelineSettings) async
    func start(workspace: Workspace, config: LiveTranscriptionPipelineSettings, resultContinuation: AsyncStream<TranscriptSegment>.Continuation) async throws
    func process(_ chunk: LiveAudioChunk, anchor: HostNanoseconds?) async
    func stop() async -> LiveSessionResult
}

actor LiveTranscriptionService: LiveTranscribing {
    private let logger = Logger(subsystem: "Scriberman", category: "LiveTranscriptionService")
    private let fileManager = FileManager.default
    private let modelPathResolver = ModelPathResolver()

    // Core managers for the current recording, taken from the preparation
    // by start().
    private var asrManager: AsrManager?
    private var diarizer: DiarizerManager?
    private var vadStreamProcessor: (any LiveVADStreamingProcessing)?

    // Single-flight model preparation shared by prepare() and start()
    // (design D3).
    private let modelLoader: LiveModelLoader
    private let processor: @Sendable () -> AsrProcessor
    private var preparation: (key: LivePreparationKey, task: Task<LivePreparedModels, Error>)?

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

    // True while a started recording has its managers installed.
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
    // Samples received per source (after gap fill and overlap trim). The
    // turn diarizer timeline and fallback offsets use this.
    private var totalSamplesProcessed: [AudioSource: Int] = [:]
    // Samples per source already fed to the VAD; start of the next VAD chunk
    // (design D1). Trails `totalSamplesProcessed` by the pending remainder.
    private var vadConsumedSamples: [AudioSource: Int] = [:]
    private var lastFinalSegmentEndOffsets: [AudioSource: Float] = [:]
    private var decoderStates: [AudioSource: TdtDecoderState] = [:]
#if DEBUG
    private var processChunkHookForTesting: (@Sendable ([Float], AudioSource, Float) async -> Void)?
    private var asrTranscribeHookForTesting: (@Sendable ([Float], AudioSource, inout TdtDecoderState) async throws -> ASRResult)?
    private var clusterDiarizationHookForTesting: (@Sendable ([Float]) throws -> [TimedSpeakerSegment])?
    private var decoderStateFactoryForTesting: (@Sendable (AsrManager) async throws -> TdtDecoderState)?
#endif

    // Authoritative record of all final segments accumulated this session
    private var collectedFinalSegments: [TranscriptSegment] = []

    // Speaker identities of the session: turn-diarizer indices, and clustering speakers for
    // chunks attributed without a turn timeline.
    private(set) var speakerIdentities: [LiveSpeakerReference: SessionSpeakerIdentity] = [:]
    // The identity behind every emitted segment, so stop() relabels by segment, not by name.
    private var segmentReferences: [UUID: LiveSpeakerReference] = [:]

    private var resultContinuation: AsyncStream<TranscriptSegment>.Continuation?
    private var captureAnchor: HostNanoseconds?

    // task 3.1: SpeakerEmbeddingStore injected via init
    init(
        speakerEmbeddingStore: SpeakerEmbeddingStore? = nil,
        modelLoader: LiveModelLoader = .workspace,
        processor: @escaping @Sendable () -> AsrProcessor = { AsrProcessor.current() }
    ) {
        self.speakerEmbeddingStore = speakerEmbeddingStore
        self.modelLoader = modelLoader
        self.processor = processor
    }

    // MARK: - Model Preparation (design D3)

    /// Loads models for `workspace` and `config` without starting a recording.
    /// Joins a preparation already running or finished for the same key.
    func prepare(workspace: Workspace, config: LiveTranscriptionPipelineSettings = .defaults) async {
        logger.info("Pre-warming live transcription models...")
        do {
            _ = try await preparedModels(workspace: workspace, config: config)
            logger.info("LiveTranscriptionService pre-warming complete")
        } catch {
            logger.error("Model preparation failed: \(error). Live transcription unavailable.")
        }
    }

    /// Returns the models for this key: the stored preparation when the key
    /// matches, otherwise a new one that replaces it. A failed preparation is
    /// cleared so the next call retries.
    private func preparedModels(workspace: Workspace, config: LiveTranscriptionPipelineSettings) async throws -> LivePreparedModels {
        let key = LivePreparationKey(
            workspaceRoot: workspace.rootURL,
            modelRevision: Self.modelRevision,
            construction: LiveConstructionSettings(config),
            processor: processor()
        )
        let task: Task<LivePreparedModels, Error>
        if let preparation, preparation.key == key {
            task = preparation.task
        } else {
            let loader = modelLoader
            let logger = logger
            task = Task {
                try await Self.loadModels(
                    workspace: workspace,
                    construction: key.construction,
                    processor: key.processor,
                    loader: loader,
                    logger: logger
                )
            }
            // A replaced task still finishes for callers already awaiting it.
            preparation = (key, task)
        }

        do {
            return try await task.value
        } catch {
            if preparation?.task == task {
                preparation = nil
            }
            throw error
        }
    }

    private static func loadModels(
        workspace: Workspace,
        construction: LiveConstructionSettings,
        processor: AsrProcessor,
        loader: LiveModelLoader,
        logger: Logger
    ) async throws -> LivePreparedModels {
        let asrManager = try await loader.loadAsr(workspace, processor)
        logger.info("AsrManager initialized")
        let makeDiarizer = try await loader.loadDiarizer(workspace, construction)
        logger.info("Diarizer models loaded from workspace")
        let vadProcessor = try await loader.loadVad(workspace, construction)
        logger.info("VAD model loaded from workspace (threshold \(construction.vadThreshold))")
        let makeTurnDiarizers = try await loader.loadTurnDiarizers(workspace)
        logger.info("Turn diarizer models loaded from workspace")
        return LivePreparedModels(
            asrManager: asrManager,
            vadProcessor: vadProcessor,
            makeDiarizer: makeDiarizer,
            makeTurnDiarizers: makeTurnDiarizers
        )
    }

    /// Model versions every load path uses. Part of the preparation key.
    private static var modelRevision: String {
        "\(ModelPathResolver.asrModelVersion)|\(ModelPathResolver.nemotron3BundleRelativePath)"
    }

    // MARK: - Lifecycle

    func start(workspace: Workspace, config: LiveTranscriptionPipelineSettings = .defaults, resultContinuation: AsyncStream<TranscriptSegment>.Continuation) async throws {
        self.resultContinuation = resultContinuation
        logger.info("Starting live transcription service (Offline Chunking Mode)")

        captureAnchor = nil
        audioConverters.removeAll()
        vadStreamStates.removeAll()
        speechAccumulationBuffers.removeAll()
        speechStartOffsets.removeAll()
        recentPreRollChunks.removeAll()
        vadInputRemainders.removeAll()
        totalSamplesProcessed.removeAll()
        vadConsumedSamples.removeAll()
        lastFinalSegmentEndOffsets.removeAll()
        decoderStates.removeAll()
        collectedFinalSegments.removeAll()
        speakerIdentities.removeAll()
        segmentReferences.removeAll()
        turnUnreliableFromOffsets.removeAll()
        pendingAttributions.removeAll()

        storedConfig = config

        let models: LivePreparedModels
        do {
            models = try await preparedModels(workspace: workspace, config: config)
        } catch {
            logger.error("Live transcription start failed: \(error)")
            isInitialized = false
            resultContinuation.finish()
            self.resultContinuation = nil
            throw LiveTranscriptionError.initializationFailed
        }

        // Per-recording objects are built here, not during preparation
        // (design D3), so each recording starts from clean state.
        asrManager = models.asrManager
        vadStreamProcessor = models.vadProcessor
        diarizer = models.makeDiarizer()
        installTurnDiarizers(models.makeTurnDiarizers())
        isInitialized = true

        logger.info("LiveTranscriptionService started (turn diarizers: \(self.turnDiarizers.count))")
    }

    func stop() async -> LiveSessionResult {
        logger.info("Stopping live transcription service")
        defer {
            resultContinuation?.finish()
            resultContinuation = nil
        }

        // Audio received since the last whole VAD chunk goes through the VAD
        // before anything is finished or flushed.
        await processFinalVADRemainders()

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

        // Final speaker identities. Nothing is enrolled: speaker memory changes only through
        // user renames. The final match of every identity decides the speaker ID of all its
        // segments, including those shown under another name during recording.
        var result = LiveSessionResult(segments: [])
        for source in Set(speakerIdentities.keys.map(\.source)).sorted(by: { $0.rawValue < $1.rawValue }) {
            await reevaluateMatches(for: source)
        }

        var finalLabels: [LiveSpeakerReference: String] = [:]
        for reference in speakerIdentities.keys.sorted(by: { $0.sessionLocalID < $1.sessionLocalID }) {
            guard let identity = speakerIdentities[reference] else { continue }
            let label = identity.boundProfileName ?? reference.sessionLocalID
            finalLabels[reference] = label
            if let profileID = identity.boundProfileID, let store = speakerEmbeddingStore {
                try? await store.updateProfile(id: profileID)
            }
            // The first voiceprint recorded under a label is kept.
            if identity.hasMatchableVoiceprint, result.speakerEmbeddings[label] == nil {
                result.speakerEmbeddings[label] = identity.averagedEmbedding
            }
        }
        for (segmentID, reference) in segmentReferences {
            if let label = finalLabels[reference] {
                result.finalSpeakerIDs[segmentID] = label
            }
        }

        result.segments = collectedFinalSegments.map { $0.relabelled(using: result.finalSpeakerIDs) }

        // Cleanup: release the models; the next recording prepares again.
        collectedFinalSegments.removeAll()
        speakerIdentities.removeAll()
        segmentReferences.removeAll()
        audioConverters.removeAll()
        vadStreamStates.removeAll()
        speechAccumulationBuffers.removeAll()
        speechStartOffsets.removeAll()
        recentPreRollChunks.removeAll()
        vadInputRemainders.removeAll()
        totalSamplesProcessed.removeAll()
        vadConsumedSamples.removeAll()
        lastFinalSegmentEndOffsets.removeAll()
        decoderStates.removeAll()
        asrManager = nil
        diarizer = nil
        vadStreamProcessor = nil
        preparation = nil
        installTurnDiarizers([:])
        turnUnreliableFromOffsets.removeAll()
        pendingAttributions.removeAll()
        releasingSources.removeAll()
        isInitialized = false

        return result
    }

    // MARK: - Audio Processing

    func process(_ chunk: LiveAudioChunk, anchor: HostNanoseconds? = nil) async {
        if captureAnchor == nil { captureAnchor = anchor }
        await process(samples: chunk.samples, source: chunk.source, sampleRate: chunk.sampleRate, hostTime: chunk.hostTime)
    }

    func process(samples: [Float], source: AudioSource, sampleRate: Double, hostTime: HostNanoseconds? = nil) async {
        do {
            if audioConverters[source] == nil {
                audioConverters[source] = AudioConverter()
            }
            var resampled = try audioConverters[source]!.resample(samples, from: sampleRate)
            if let hostTime {
                if captureAnchor == nil { captureAnchor = hostTime }
                let timeline = SynchronizedAudioTimeline(sampleRate: Double(Self.SAMPLE_RATE), referenceTime: 0)
                let position = hostTime.seconds(since: captureAnchor!)
                let written = totalSamplesProcessed[source] ?? 0
                let gap = timeline.gapFrames(before: position, writtenFrames: written)
                // Match saved audio placement, including overlapping capture buffers.
                if gap > 0 {
                    resampled.insert(contentsOf: repeatElement(0, count: gap), at: 0)
                } else if let expected = timeline.expectedStartFrame(for: position), expected < written {
                    resampled.removeFirst(min(written - expected, resampled.count))
                }
            }
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
            guard vadStreamProcessor != nil else { return }

            for startIndex in stride(from: 0, to: processableCount, by: chunkSize) {
                let chunk = Array(combinedSamples[startIndex..<(startIndex + chunkSize)])
                try await processVADChunk(chunk, realCount: chunkSize, source: source)
            }
        } catch {
            logger.error("Error processing live audio (\(source.rawValue)): \(error.localizedDescription)")
        }
    }

    /// Runs one `VAD_CHUNK_SIZE` chunk through the VAD. Only the first
    /// `realCount` samples are audio; the rest is zero padding (stop-time
    /// remainder, design D2) and never enters the speech buffer. The chunk
    /// starts at `vadConsumedSamples`, which advances by `realCount`.
    private func processVADChunk(_ chunk: [Float], realCount: Int, source: AudioSource) async throws {
        guard let vadStreamProcessor else { return }
        let chunkStartSamples = vadConsumedSamples[source] ?? 0
        vadConsumedSamples[source] = chunkStartSamples + realCount
        let realSamples = realCount == chunk.count ? chunk : Array(chunk.prefix(realCount))

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
            let triggerOffset = Float(chunkStartSamples) / Self.SAMPLE_RATE
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
            speechBuffer.append(contentsOf: realSamples)
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
                speechBuffer.append(contentsOf: realSamples)
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
            appendPreRollChunk(realSamples, for: source)
        }
    }

    /// Feeds each source's leftover samples, zero-padded to a full chunk, so
    /// audio received since the last whole chunk reaches the VAD (design D2).
    private func processFinalVADRemainders() async {
        for source in Array(vadInputRemainders.keys) {
            guard let remainder = vadInputRemainders[source], !remainder.isEmpty else { continue }
            vadInputRemainders[source] = []
            let padded = remainder + [Float](repeating: 0, count: Self.VAD_CHUNK_SIZE - remainder.count)
            do {
                try await processVADChunk(padded, realCount: remainder.count, source: source)
            } catch {
                logger.error("Error processing final VAD remainder (\(source.rawValue)): \(error.localizedDescription)")
            }
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
            var chunkClusterSegments: [TimedSpeakerSegment] = []
            do {
                chunkClusterSegments = try clusterSegments(for: samples)
            } catch {
                logger.error("Embedding diarization failed: \(error)")
            }

            pendingAttributions[source, default: []].append(PendingAttribution(
                text: cleanedText,
                tokenTimings: asrResult.tokenTimings,
                start: currentOffset,
                end: currentOffset + chunkDuration,
                clusterSegments: chunkClusterSegments
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
        let runs = turnSpeakerRuns(for: source, start: bufferStart, end: bufferEnd)
        let parts = LiveSegmentSplitter.planParts(runs: runs, start: bufferStart, end: bufferEnd)

        guard !parts.isEmpty else {
            // Timeline has no reliable data for this range: fall back to
            // embedding-based attribution (pre-turn-diarizer behavior).
            let reference = await fallbackReference(from: findLongestSpeaker(in: pending.clusterSegments), source: source)
            let speakerID = reference.map(speakerLabel(for:)) ?? "unknown"
            logger.info("📝 RESULT [\(source.rawValue)] (embedding fallback): \(speakerID): \(cleanedText)")
            emitFinalSegment(speakerId: speakerID, reference: reference, text: cleanedText, start: bufferStart, end: bufferEnd, source: source)
            return
        }

        // Each turn speaker accumulates the clustering embedding recorded inside
        // its own runs; the source's matches are then re-evaluated (design D4).
        let assignments = LiveEmbeddingAttribution.assignments(
            clusterSegments: pending.clusterSegments,
            runs: runs,
            bufferStart: bufferStart
        )
        for (speakerIndex, assignment) in assignments.sorted(by: { $0.key < $1.key }) {
            let segment = assignment.segment
            logger.info("📍 Turn speaker \(speakerIndex) (\(source.rawValue)) takes clustering \(segment.speakerId) \(String(format: "%.2f", bufferStart + segment.startTimeSeconds))–\(String(format: "%.2f", bufferStart + segment.endTimeSeconds))s, \(String(format: "%.0f", assignment.overlapFraction * 100))% inside its runs")
            speakerIdentities[.turn(source, speakerIndex), default: SessionSpeakerIdentity()]
                .accumulate(segment.embedding, seconds: segment.durationSeconds)
        }
        if !assignments.isEmpty {
            await reevaluateMatches(for: source)
        }

        let texts = LiveSegmentSplitter.apportionText(
            cleanedText,
            parts: parts,
            bufferStart: bufferStart,
            tokenTimings: pending.tokenTimings
        )

        for (part, text) in zip(parts, texts) where !text.isEmpty {
            let reference = LiveSpeakerReference.turn(source, part.speakerIndex)
            let speakerID = speakerLabel(for: reference)
            logger.info("📝 RESULT [\(source.rawValue)]: \(speakerID): \(text)")
            emitFinalSegment(speakerId: speakerID, reference: reference, text: text, start: part.start, end: part.end, source: source)
        }
    }

    /// Current label of a speaker identity: its matched profile's name, or its session-local ID.
    private func speakerLabel(for reference: LiveSpeakerReference) -> String {
        speakerIdentities[reference]?.boundProfileName ?? reference.sessionLocalID
    }

    /// Attribution used when the timeline has no data for a buffer: the chunk's longest
    /// clustering speaker, as an identity of this source. Its embedding counts only when the
    /// segment is long enough, and the source's matches are then re-evaluated.
    private func fallbackReference(
        from longestSegment: TimedSpeakerSegment?,
        source: AudioSource
    ) async -> LiveSpeakerReference? {
        guard let longestSegment else {
            logger.info("📍 No speaker detected in audio chunk")
            return nil
        }

        let reference = LiveSpeakerReference.fallback(source, longestSegment.speakerId)
        var identity = speakerIdentities[reference] ?? SessionSpeakerIdentity()
        if longestSegment.durationSeconds >= SessionSpeakerIdentity.minimumEmbeddingSeconds {
            identity.accumulate(longestSegment.embedding, seconds: longestSegment.durationSeconds)
            speakerIdentities[reference] = identity
            await reevaluateMatches(for: source)
        } else {
            speakerIdentities[reference] = identity
        }
        return reference
    }

    /// Matches every identity of `source` with enough speech against stored profiles, giving each
    /// profile to at most one of them. Identities below the minimum speech, or matching no
    /// profile, are left unmatched. A match may change between evaluations (design D4).
    private func reevaluateMatches(for source: AudioSource) async {
        let references = speakerIdentities.keys
            .filter { $0.source == source }
            .sorted { $0.sessionLocalID < $1.sessionLocalID }
        let queries = references.compactMap { reference -> (label: String, embedding: [Float])? in
            guard let identity = speakerIdentities[reference], identity.hasMatchableVoiceprint else { return nil }
            return (reference.sessionLocalID, identity.averagedEmbedding)
        }

        var matches: [String: SpeakerProfileSnapshot] = [:]
        if !queries.isEmpty, let store = speakerEmbeddingStore {
            let profiles = (try? await store.fetchAllSnapshots()) ?? []
            matches = speakerMatcher.assign(queries, to: profiles)
        }

        for reference in references {
            guard var identity = speakerIdentities[reference] else { continue }
            let match = matches[reference.sessionLocalID]
            if identity.boundProfileID != match?.id {
                logger.notice("📍 Speaker \(reference.sessionLocalID, privacy: .public) match changed to \(match?.id.uuidString ?? "none", privacy: .public)")
            }
            identity.boundProfileID = match?.id
            identity.boundProfileName = match?.name
            speakerIdentities[reference] = identity
        }
    }

    private func emitFinalSegment(
        speakerId: String,
        reference: LiveSpeakerReference?,
        text: String,
        start: Float,
        end: Float,
        source: AudioSource
    ) {
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
        if let reference {
            segmentReferences[segment.id] = reference
        }
        lastFinalSegmentEndOffsets[source] = segment.endTime
        resultContinuation?.yield(segment)
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

    /// Clustering-diarizer segments for one chunk, in chunk-relative seconds.
    private func clusterSegments(for samples: [Float]) throws -> [TimedSpeakerSegment] {
#if DEBUG
        if let clusterDiarizationHookForTesting {
            return try clusterDiarizationHookForTesting(samples)
        }
#endif
        guard let diarizer else { return [] }
        return try diarizer.performCompleteDiarization(samples, sampleRate: 16000).segments
    }

    private func findLongestSpeaker(in segments: [TimedSpeakerSegment]) -> TimedSpeakerSegment? {
        var longestSegment: TimedSpeakerSegment?
        var maxDuration: Float = 0

        for segment in segments {
            let duration = segment.endTimeSeconds - segment.startTimeSeconds
            if duration > maxDuration {
                maxDuration = duration
                longestSegment = segment
            }
        }

        return longestSegment
    }
}

#if DEBUG
extension LiveTranscriptionService {
    func setResultContinuationForTesting(_ continuation: AsyncStream<TranscriptSegment>.Continuation) {
        resultContinuation = continuation
    }

    func processedSampleCountForTesting(source: AudioSource) -> Int {
        totalSamplesProcessed[source] ?? 0
    }

    func setTurnDiarizersForTesting(_ diarizers: [AudioSource: any StreamingTurnDiarizing]) {
        installTurnDiarizers(diarizers)
    }

    func pendingAttributionCountForTesting(source: AudioSource) -> Int {
        pendingAttributions[source]?.count ?? 0
    }

    func injectSpeakerIdentityForTesting(source: AudioSource, speakerIndex: Int, identity: SessionSpeakerIdentity) {
        speakerIdentities[.turn(source, speakerIndex)] = identity
    }

    func speakerIdentityForTesting(source: AudioSource, speakerIndex: Int) -> SessionSpeakerIdentity? {
        speakerIdentities[.turn(source, speakerIndex)]
    }

    func speakerIdentityForTesting(_ reference: LiveSpeakerReference) -> SessionSpeakerIdentity? {
        speakerIdentities[reference]
    }

    func injectSpeakerIdentityForTesting(_ reference: LiveSpeakerReference, identity: SessionSpeakerIdentity) {
        speakerIdentities[reference] = identity
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

    func setClusterDiarizationHookForTesting(_ hook: @escaping @Sendable ([Float]) throws -> [TimedSpeakerSegment]) {
        self.clusterDiarizationHookForTesting = hook
    }

    func setDecoderStateFactoryForTesting(_ factory: @escaping @Sendable (AsrManager) async throws -> TdtDecoderState) {
        self.decoderStateFactoryForTesting = factory
    }
}
#endif
