import FluidAudio
import Foundation

struct TranscriptionPassRunner: @unchecked Sendable {
    struct SpeechSegment {
        let startTime: Double
        let endTime: Double
    }

    struct PassASRResult {
        let text: String
        let tokenTimings: [TokenTiming]
        let confidence: Float

        init(text: String, tokenTimings: [TokenTiming], confidence: Float = 1.0) {
            self.text = text
            self.tokenTimings = tokenTimings
            self.confidence = confidence
        }
    }

    struct PassDiarizationResult {
        let segments: [TimedSpeakerSegment]
        let speakerDatabase: [String: [Float]]?
    }

    // @unchecked: the closures capture FluidAudio managers (AsrManager is an
    // actor; OfflineDiarizerManager is serialized by the diarize gate) so one
    // engines instance can be shared across the concurrent mic/app passes.
    struct PassEngines: @unchecked Sendable {
        let transcribeChunk: ([Float], AudioSource) async throws -> PassASRResult
        let diarize: ([Float]) async throws -> PassDiarizationResult
    }

    /// Memoizes the first `MakePassEngines` call so the concurrent mic/app
    /// passes of one transcription request share a single model load, while
    /// keeping the load lazy (no models load when VAD finds no speech).
    final class SharedPassEngines: @unchecked Sendable {
        private let lock = NSLock()
        private let factory: MakePassEngines
        private var task: Task<PassEngines, Error>?

        init(factory: @escaping MakePassEngines) {
            self.factory = factory
        }

        func engines(for workspace: Workspace) async throws -> PassEngines {
            let task = lock.withLock {
                if let task = self.task { return task }
                let factory = self.factory
                let created = Task { try await factory(workspace) }
                self.task = created
                return created
            }
            return try await task.value
        }
    }

    typealias SegmentSpeech = ([Float]) async throws -> [SpeechSegment]
    typealias MakePassEngines = @Sendable (Workspace) async throws -> PassEngines
    typealias AlignTranscript = (String, [TokenTiming], [TimedSpeakerSegment], AudioSource) -> Transcript

    private let speakerEmbeddingStore: SpeakerEmbeddingStore?
    private let minimumChunkSamples: Int
    private let pipelineSettings: LiveTranscriptionPipelineSettings
    private let speakerMatcher: SpeakerMatcher
    private let segmentSpeech: SegmentSpeech
    private let makePassEngines: MakePassEngines
    private let alignTranscript: AlignTranscript

    /// VAD configuration derived from user pipeline settings; every field not
    /// covered by settings keeps the FluidAudio default (including the 14s
    /// max-speech cap that keeps segments inside the 15s encoder window).
    static func makeVadConfiguration(
        settings: LiveTranscriptionPipelineSettings
    ) -> (config: VadConfig, segmentation: VadSegmentationConfig) {
        let config = VadConfig(defaultThreshold: Float(settings.vadThreshold))
        var segmentation = VadSegmentationConfig.default
        segmentation.minSpeechDuration = settings.vadMinSpeechDuration
        return (config, segmentation)
    }

    private static func makeDefaultSegmentSpeech(
        settings: LiveTranscriptionPipelineSettings
    ) -> SegmentSpeech {
        { samples in
            let (config, segmentation) = makeVadConfiguration(settings: settings)
            let vadManager = try await VadManager(config: config)
            let segments = try await vadManager.segmentSpeech(samples, config: segmentation)
            return segments.map { segment in
                SpeechSegment(startTime: segment.startTime, endTime: segment.endTime)
            }
        }
    }

    init(
        speakerEmbeddingStore: SpeakerEmbeddingStore? = nil,
        minimumChunkSamples: Int = 16_000,
        pipelineSettings: LiveTranscriptionPipelineSettings = .defaults,
        speakerMatcher: SpeakerMatcher = SpeakerMatcher(),
        segmentSpeech: SegmentSpeech? = nil,
        makePassEngines: MakePassEngines? = nil,
        alignTranscript: AlignTranscript? = nil
    ) {
        self.speakerEmbeddingStore = speakerEmbeddingStore
        self.minimumChunkSamples = minimumChunkSamples
        self.pipelineSettings = pipelineSettings
        self.speakerMatcher = speakerMatcher
        self.segmentSpeech = segmentSpeech ?? Self.makeDefaultSegmentSpeech(settings: pipelineSettings)
        self.makePassEngines = makePassEngines ?? Self.defaultMakePassEngines(modelPathResolver: ModelPathResolver())
        let transcriptAligner = TranscriptAligner()
        self.alignTranscript = alignTranscript ?? { fullText, tokenTimings, diarizedSegments, source in
            transcriptAligner.alignTranscript(
                fullText: fullText,
                tokenTimings: tokenTimings,
                diarizedSegments: diarizedSegments,
                source: source
            )
        }
    }

    func run(samples: [Float], source: AudioSource, workspace: Workspace) async throws -> ([TranscriptSegment], [String: [Float]]) {
        let passName = source == .app ? "app" : "mic"
        let speechSegments: [SpeechSegment]
        do {
            speechSegments = try await segmentSpeech(samples)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: VAD failed - \(error.localizedDescription)")
        }

        guard !speechSegments.isEmpty else {
            return ([], [:])
        }

        let passEngines: PassEngines
        do {
            passEngines = try await makePassEngines(workspace)
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: model initialization failed - \(error.localizedDescription)")
        }

        var globalTokenTimings: [TokenTiming] = []
        var allASRTexts: [String] = []
        for speechSegment in speechSegments {
            let startIndex = max(0, Int(speechSegment.startTime * 16_000.0))
            let endIndex = min(samples.count, max(startIndex + 1, Int(speechSegment.endTime * 16_000.0)))
            guard startIndex < endIndex else {
                continue
            }

            var chunkSamples = Array(samples[startIndex..<endIndex])
            if chunkSamples.count < minimumChunkSamples {
                let missing = minimumChunkSamples - chunkSamples.count
                chunkSamples.append(contentsOf: Array(repeating: 0, count: missing))
            }

            let asrResult: PassASRResult
            do {
                asrResult = try await passEngines.transcribeChunk(chunkSamples, source)
            } catch {
                throw TranscriptionError.failedToTranscribe("\(passName) pass: ASR failed - \(error.localizedDescription)")
            }

            // Same gate as live: 0 disables; below-gate results (typically
            // hallucinations from near-silence segments) are discarded whole.
            let confidenceGate = Float(pipelineSettings.asrConfidenceGate)
            if confidenceGate > 0, asrResult.confidence < confidenceGate {
                continue
            }

            let trimmedText = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                allASRTexts.append(trimmedText)
            }

            let offsetTimings = asrResult.tokenTimings.map { timing in
                TokenTiming(
                    token: timing.token,
                    tokenId: timing.tokenId,
                    startTime: timing.startTime + speechSegment.startTime,
                    endTime: timing.endTime + speechSegment.startTime,
                    confidence: timing.confidence
                )
            }
            globalTokenTimings.append(contentsOf: offsetTimings)
        }

        let fullASRText = allASRTexts.joined(separator: " ")

        let diarizationResult: PassDiarizationResult
        do {
            diarizationResult = try await passEngines.diarize(samples)
        } catch {
            throw TranscriptionError.failedToTranscribe("\(passName) pass: Offline diarization failed - \(error.localizedDescription)")
        }

        let speakerMapping = try await matchSpeakers(speakerDatabase: diarizationResult.speakerDatabase)

        let alignedTranscript = alignTranscript(
            fullASRText,
            globalTokenTimings,
            diarizationResult.segments,
            source
        )

        let finalSegments = alignedTranscript.segments.compactMap { segment -> TranscriptSegment? in
            // Same emit gauntlet as live's emitFinalSegment: sanitize, then
            // user cleanup rules; a segment emptied by either step is dropped.
            guard let sanitizedText = LiveSegmentSanitizer.sanitize(segment.text),
                  let cleanedText = TranscriptCleanupEngine.apply(pipelineSettings.cleanupRules, to: sanitizedText)
            else {
                return nil
            }

            let baseId = segment.speakerId
            let mappedName = speakerMapping[baseId]
            let finalSpeakerId = mappedName ?? baseId

            let speakerId: String
            if source == .app {
                speakerId = finalSpeakerId.hasPrefix("app:") ? finalSpeakerId : "app:\(finalSpeakerId)"
            } else {
                speakerId = finalSpeakerId
            }
            return TranscriptSegment(
                speakerId: speakerId,
                text: cleanedText,
                startTime: segment.startTime,
                endTime: segment.endTime,
                audioSource: source
            )
        }

        var finalEmbeddings: [String: [Float]] = [:]
        if let db = diarizationResult.speakerDatabase {
            for (baseId, embedding) in db {
                let mappedName = speakerMapping[baseId]
                let finalSpeakerId = mappedName ?? baseId

                let speakerId: String
                if source == .app {
                    speakerId = finalSpeakerId.hasPrefix("app:") ? finalSpeakerId : "app:\(finalSpeakerId)"
                } else {
                    speakerId = finalSpeakerId
                }
                finalEmbeddings[speakerId] = embedding
            }
        }

        return (finalSegments, finalEmbeddings)
    }

    func matchSpeakers(diarizationResult: DiarizationResult) async throws -> [String: String] {
        try await matchSpeakers(speakerDatabase: diarizationResult.speakerDatabase)
    }

    private func matchSpeakers(speakerDatabase: [String: [Float]]?) async throws -> [String: String] {
        var speakerMapping: [String: String] = [:]
        guard let store = speakerEmbeddingStore, let db = speakerDatabase else {
            return [:]
        }

        let profiles = (try? await store.fetchAllSnapshots()) ?? []

        for (clusterId, embedding) in db {
            if let match = speakerMatcher.findBestMatch(for: embedding, in: profiles) {
                speakerMapping[clusterId] = match.name
                try? await store.updateProfile(id: match.id)
            }
        }

        return speakerMapping
    }

    static func defaultMakePassEngines(modelPathResolver: ModelPathResolver) -> MakePassEngines {
        { workspace in
            let asrManager = AsrManager(config: .default)
            let offlineDiarizerManager = OfflineDiarizerManager(config: .default)

            let asrModelDirectory = try modelPathResolver.modelDirectory(for: .asrParakeetV3, in: workspace)
            let asrModels = try await AsrModels.load(from: asrModelDirectory, encoderComputeUnits: .cpuAndGPU)
            try await asrManager.loadModels(asrModels)

            let diarizerModels = try await OfflineDiarizerModels.load(from: workspace.modelsURL)
            offlineDiarizerManager.initialize(models: diarizerModels)

            // OfflineDiarizerManager is a plain class; when one engines
            // instance is shared across concurrent passes, its process calls
            // must not interleave.
            let diarizeGate = SerialAsyncGate()

            return PassEngines(
                transcribeChunk: { chunkSamples, _ in
                    var decoderState = try TdtDecoderState()
                    let result = try await asrManager.transcribe(chunkSamples, decoderState: &decoderState)
                    return PassASRResult(
                        text: result.text,
                        tokenTimings: result.tokenTimings ?? [],
                        confidence: result.confidence
                    )
                },
                diarize: { inputSamples in
                    await diarizeGate.wait()
                    defer { diarizeGate.signal() }
                    let result = try await offlineDiarizerManager.process(audio: inputSamples)
                    return PassDiarizationResult(
                        segments: result.segments,
                        speakerDatabase: result.speakerDatabase
                    )
                }
            )
        }
    }
}

/// Minimal FIFO mutex for async code: `wait()` suspends until the gate is
/// free, `signal()` hands it to the next waiter. Unlike an actor, held
/// isolation spans the awaited work between wait and signal.
final class SerialAsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        let acquired = lock.withLock { () -> Bool in
            if !isBusy {
                isBusy = true
                return true
            }
            return false
        }
        if acquired { return }

        await withCheckedContinuation { continuation in
            let acquiredNow = lock.withLock { () -> Bool in
                if !isBusy {
                    isBusy = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if acquiredNow { continuation.resume() }
        }
    }

    func signal() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty {
                isBusy = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
