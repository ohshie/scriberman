import CoreAudio
import CoreML
import FluidAudio
import Foundation
import OSLog
import Observation

enum DictationState: Equatable {
    case idle
    case prewarming
    case listening
    case transcribing
    case inserting
}

enum DictationFailureReason: Equatable {
    case noModel
    case captureFailed
    case emptyTranscript
    case insertionFailed
    /// Hotkey released before the first audio buffer arrived — the capture
    /// system is fine, the hold was just shorter than buffer delivery.
    case tooShort
}

enum DictationOutcome: Equatable {
    case inserted
    case typedOut
    case copiedToClipboard
    case failed(DictationFailureReason)

    init(_ insertion: InsertionOutcome) {
        switch insertion {
        case .insertedDirectly: self = .inserted
        case .typedOut: self = .typedOut
        case .copiedToClipboard: self = .copiedToClipboard
        case .failed: self = .failed(.insertionFailed)
        }
    }
}

@Observable
@MainActor
final class DictationService {
    private let logger = Logger(subsystem: "Scriberman", category: "DictationService")

    /// ASR minimum accepted buffer: 300ms at 16 kHz. Shorter captures are
    /// zero-padded to this floor rather than dropped (design D3).
    static let minimumSampleCount = 4_800

    private(set) var state: DictationState = .idle
    /// Outcome of the most recent completed session, for HUD display.
    private(set) var lastOutcome: DictationOutcome?
    /// Live input RMS while listening, for HUD level display.
    private(set) var inputLevel: Float = 0

    // nonisolated(unsafe): written once during prewarm (on main actor), then read by the processing
    // Task which only runs after prewarm completes and never concurrently with another write.
    @ObservationIgnored nonisolated(unsafe) private var asrManager: AsrManager?
    /// The model a press started with. A processor change reloads `asrManager`,
    /// and a press in progress finishes on the model it started with.
    @ObservationIgnored private var pressAsrManager: AsrManager?
    @ObservationIgnored private let loadAsr: @Sendable (Workspace, AsrProcessor) async throws -> AsrManager
    @ObservationIgnored private let processor: @Sendable () -> AsrProcessor
    // Single-flight pre-warm (design D4): callers with the same key join
    // this task; a failed load clears it so the next call retries.
    @ObservationIgnored private var prewarmLoad: (key: PrewarmKey, task: Task<Void, Never>)?

    private var preparedWorkspace: Workspace?

    private struct PrewarmKey: Equatable {
        let workspaceRoot: URL
        let modelRevision: String
        let processor: AsrProcessor
    }

    @ObservationIgnored private let captureSession: any DictationCapturing
    @ObservationIgnored private let insertText: @MainActor (String) -> InsertionOutcome
    @ObservationIgnored private let recordingService: any RecordingServiceProtocol
    @ObservationIgnored private let mode: @MainActor () -> DictationMode
    // Progressive typing needs Accessibility; without it insertion would copy each
    // committed word to the clipboard, so such presses run release-time instead.
    @ObservationIgnored private let canTypeDuringHold: @MainActor () -> Bool

    /// New audio a progressive pass waits for before it starts: 1 s at 16 kHz.
    static let progressivePassIntervalSamples = 16_000
    /// Audio after the last finished pass counts as silent below this peak
    /// amplitude, and that pass is then used as the final one (design D4).
    static let silencePeak: Float = 0.03
    private static let sampleRate = 16_000.0

    // Serialization (design D3): stop() awaits the in-flight start before
    // touching the session, so a quick press-release cannot interleave and
    // strand the service in .listening.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var levelHandlerInstalled = false

#if DEBUG
    @ObservationIgnored var transcribeHookForTesting: (@Sendable ([Float]) async -> String?)?
    /// Progressive passes: returns the pass's words timed from the start of its audio.
    @ObservationIgnored var progressivePassHookForTesting: (@Sendable ([Float]) async -> [WordTiming]?)?
    var pressModelForTesting: AsrManager? { pressAsrManager }
    var loadedModelForTesting: AsrManager? { asrManager }
#endif

    init(
        recordingService: any RecordingServiceProtocol,
        captureSession: any DictationCapturing = DictationCaptureSession(),
        insertText: @escaping @MainActor (String) -> InsertionOutcome = { TextInjector().insert($0) },
        loadAsr: @escaping @Sendable (Workspace, AsrProcessor) async throws -> AsrManager = DictationService.loadWorkspaceAsr,
        processor: @escaping @Sendable () -> AsrProcessor = { AsrProcessor.current() },
        mode: @escaping @MainActor () -> DictationMode = { .releaseTime },
        canTypeDuringHold: @escaping @MainActor () -> Bool = { TextInjector().isAccessibilityGranted }
    ) {
        self.recordingService = recordingService
        self.captureSession = captureSession
        self.insertText = insertText
        self.loadAsr = loadAsr
        self.processor = processor
        self.mode = mode
        self.canTypeDuringHold = canTypeDuringHold
    }

    // MARK: - Pre-warm

    func prepare(for workspace: Workspace) {
        guard preparedWorkspace != workspace else { return }
        preparedWorkspace = workspace
        prewarmLoad?.task.cancel()
        prewarmLoad = nil
        asrManager = nil
        if state == .prewarming { state = .idle }
    }

    func prewarm(workspace: Workspace) async {
        guard !Task.isCancelled else { return }
        prepare(for: workspace)
        let processor = processor()
        let key = PrewarmKey(
            workspaceRoot: workspace.rootURL,
            modelRevision: "\(ModelPathResolver.asrModelVersion)",
            processor: processor
        )
        if let prewarmLoad, prewarmLoad.key == key {
            await prewarmLoad.task.value
            return
        }

        // A reload for a new processor keeps serving presses with the loaded model.
        if state == .idle, asrManager == nil {
            state = .prewarming
        }
        prewarmLoad?.task.cancel()
        let loadAsr = loadAsr
        // The task body updates state itself, so every caller awaiting it
        // resumes with the load already applied.
        let task = Task { [weak self] in
            do {
                let asr = try await loadAsr(workspace, processor)
                guard !Task.isCancelled else { return }
                self?.asrManager = asr
                self?.logger.info("DictationService pre-warm complete")
            } catch {
                guard !Task.isCancelled else { return }
                self?.logger.warning("DictationService pre-warm failed (non-fatal): \(error.localizedDescription)")
                if self?.prewarmLoad?.key == key {
                    self?.prewarmLoad = nil
                }
            }
            if self?.state == .prewarming {
                self?.state = .idle
            }
        }
        prewarmLoad = (key, task)
        await task.value
    }

    nonisolated static func loadWorkspaceAsr(_ workspace: Workspace, processor: AsrProcessor) async throws -> AsrManager {
        let asrDir = try ModelPathResolver().modelDirectory(for: .asrParakeetUltra, in: workspace)
        let asr = AsrManager(config: ASRConfig())
        let asrModels = try await AsrModels.load(
            from: asrDir,
            version: ModelPathResolver.asrModelVersion,
            encoderComputeUnits: processor.encoderComputeUnits
        )
        try await asr.loadModels(asrModels)
        // The first inference after a load is several times slower than later ones
        // (5.3 s vs 0.4 s measured); pay it here instead of on the first press.
        var warmUpState = try TdtDecoderState()
        _ = try await asr.transcribe([Float](repeating: 0, count: 16_000), decoderState: &warmUpState)
        return asr
    }

    // MARK: - Lifecycle

    func start(deviceID: AudioDeviceID?) async {
        guard state == .idle || state == .prewarming, startTask == nil else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            // A press during pre-warm waits for that load (design D4); a press
            // during a processor reload uses the model already loaded.
            if self.asrManager == nil {
                await self.prewarmLoad?.task.value
            }
            await self.performStart(deviceID: deviceID)
        }
        startTask = task
        await task.value
    }

    func stop() async {
        // Never interleave with an in-flight start (design D3).
        await startTask?.value
        startTask = nil

        await captureSession.stop()
        await processingTask?.value
        processingTask = nil
        pressAsrManager = nil
        inputLevel = 0
        if state == .listening {
            state = .idle
        }
    }

    private func performStart(deviceID: AudioDeviceID?) async {
        guard await !recordingService.isRecording() else {
            logger.info("Dictation blocked: recording is active")
            return
        }

        // Fresh session: the HUD must not show the previous session's outcome.
        lastOutcome = nil
        pressAsrManager = asrManager
        inputLevel = 0

        if !levelHandlerInstalled {
            levelHandlerInstalled = true
            await captureSession.setLevelHandler { [weak self] level in
                Task { @MainActor [weak self] in
                    guard let self, self.state == .listening else { return }
                    self.inputLevel = level
                }
            }
        }

        // The mode is read once: a press finishes in the mode it started with.
        let isProgressive = mode() == .progressive && canTypeDuringHold()

        do {
            let stream = try await captureSession.start(deviceID: deviceID)
            state = .listening
            if isProgressive {
                startProgressiveProcessing(stream: stream)
            } else {
                startProcessing(stream: stream)
            }
        } catch {
            logger.error("Failed to start dictation capture: \(error.localizedDescription)")
            lastOutcome = .failed(.captureFailed)
            state = .idle
        }
    }

    // MARK: - Processing

    private func startProcessing(stream: AsyncThrowingStream<[Float], Error>) {
        processingTask = Task { [weak self] in
            var allSamples: [Float] = []
            do {
                for try await samples in stream {
                    allSamples.append(contentsOf: samples)
                }
                await self?.finishSession(samples: allSamples)
            } catch {
                guard let self else { return }
                self.logger.error("Dictation conversion failed: \(error.localizedDescription)")
                await self.captureSession.stop()
                self.inputLevel = 0
                self.lastOutcome = .failed(.captureFailed)
                self.state = .idle
            }
        }
    }

    private func finishSession(samples: [Float]) async {
        defer {
            state = .idle
        }

        guard !samples.isEmpty else {
            logger.info("Dictation session ended before any audio arrived (too-short hold)")
            lastOutcome = .failed(.tooShort)
            return
        }

#if DEBUG
        let hasModel = pressAsrManager != nil || transcribeHookForTesting != nil
#else
        let hasModel = pressAsrManager != nil
#endif
        guard hasModel else {
            logger.info("Dictation failed: no ASR model loaded")
            lastOutcome = .failed(.noModel)
            return
        }

        state = .transcribing
        let padded = Self.padToMinimum(samples)
        logger.info("Dictation transcribing full buffer with \(padded.count) samples")

        guard let text = await transcribe(padded) else {
            logger.info("Dictation transcription produced no text")
            lastOutcome = .failed(.emptyTranscript)
            return
        }

        state = .inserting
        let outcome = insertText(text)
        lastOutcome = DictationOutcome(outcome)
        logger.info("Dictation outcome: \(String(describing: outcome), privacy: .public)")
    }

    /// Zero-pads short captures to the ASR minimum so quick holds still
    /// transcribe instead of being silently rejected.
    static func padToMinimum(_ samples: [Float]) -> [Float] {
        guard samples.count < minimumSampleCount else { return samples }
        return samples + [Float](repeating: 0, count: minimumSampleCount - samples.count)
    }

    private func transcribe(_ samples: [Float]) async -> String? {
#if DEBUG
        if let hook = transcribeHookForTesting {
            let text = await hook(samples)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }
#endif
        guard let asr = pressAsrManager, !samples.isEmpty else { return nil }
        do {
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            logger.error("ASR error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Progressive typing

    /// One progressive press. Main-actor state shared by the capture loop and its passes.
    @MainActor
    private final class ProgressivePress {
        var samples: [Float] = []
        var committer = ProgressiveTranscriptCommitter()
        var samplesAtLastPass = 0
        var passTask: Task<Void, Never>?
        /// The most recent finished pass: its words and the sample range it covered.
        var lastPass: (words: [WordTiming], startIndex: Int, endIndex: Int)?
        /// Set at release or on failure; pass results arriving later are discarded.
        var isClosed = false
        var insertedAny = false
        var lastInsertion: InsertionOutcome?
        /// An insertion during the hold did not reach the app; nothing more is inserted.
        var insertionStopped = false
    }

    private func startProgressiveProcessing(stream: AsyncThrowingStream<[Float], Error>) {
        let press = ProgressivePress()
        processingTask = Task { [weak self] in
            do {
                for try await samples in stream {
                    press.samples.append(contentsOf: samples)
                    self?.scheduleProgressivePass(press)
                }
                await self?.finishProgressiveSession(press)
            } catch {
                press.isClosed = true
                guard let self else { return }
                self.logger.error("Dictation conversion failed: \(error.localizedDescription)")
                await self.captureSession.stop()
                self.inputLevel = 0
                self.lastOutcome = .failed(.captureFailed)
                self.state = .idle
            }
        }
    }

    /// Starts a pass when none is running and a second of new audio has arrived.
    private func scheduleProgressivePass(_ press: ProgressivePress) {
        guard !press.isClosed, !press.insertionStopped, press.passTask == nil,
              press.samples.count - press.samplesAtLastPass >= Self.progressivePassIntervalSamples
        else { return }
        let startIndex = min(press.samples.count, Int(press.committer.passStartSeconds * Self.sampleRate))
        let endIndex = press.samples.count
        let audio = Array(press.samples[startIndex..<endIndex])
        press.samplesAtLastPass = endIndex
        press.passTask = Task { [weak self] in
            let words = await self?.transcribeWords(audio)
            press.passTask = nil
            if let words {
                press.lastPass = (words, startIndex, endIndex)
            }
            guard let self, !press.isClosed, let words else { return }
            let committed = press.committer.commit(words: words, passStart: Double(startIndex) / Self.sampleRate)
            if !committed.isEmpty {
                self.insertProgressive(committed, press: press)
            }
            self.scheduleProgressivePass(press)
        }
    }

    private func insertProgressive(_ words: [String], press: ProgressivePress) {
        let text = (press.insertedAny ? " " : "") + words.joined(separator: " ")
        let outcome = insertText(text)
        press.lastInsertion = outcome
        switch outcome {
        case .insertedDirectly, .typedOut:
            press.insertedAny = true
        case .copiedToClipboard, .failed:
            press.insertionStopped = true
            logger.info("Dictation progressive insertion stopped: \(String(describing: outcome), privacy: .public)")
        }
    }

    private func finishProgressiveSession(_ press: ProgressivePress) async {
        defer {
            state = .idle
        }
        // No pass starts after release. One still running is awaited: the model runs
        // one pass at a time, so a final pass would queue behind it anyway (design D4).
        press.isClosed = true
        await press.passTask?.value

        if press.insertionStopped {
            lastOutcome = press.lastInsertion.map(DictationOutcome.init) ?? .failed(.insertionFailed)
            return
        }

        guard !press.samples.isEmpty else {
            logger.info("Dictation session ended before any audio arrived (too-short hold)")
            lastOutcome = .failed(.tooShort)
            return
        }

#if DEBUG
        let hasModel = pressAsrManager != nil || progressivePassHookForTesting != nil
#else
        let hasModel = pressAsrManager != nil
#endif
        guard hasModel else {
            logger.info("Dictation failed: no ASR model loaded")
            lastOutcome = .failed(.noModel)
            return
        }

        state = .transcribing
        let words: [WordTiming]
        let startIndex: Int
        if let lastPass = press.lastPass, Self.isSilent(press.samples[lastPass.endIndex...]) {
            // Nothing was said after the last pass's audio ended: it is the final pass.
            words = lastPass.words
            startIndex = lastPass.startIndex
            logger.info("Dictation release reuses last pass (\(lastPass.endIndex - lastPass.startIndex, privacy: .public) samples, \(press.samples.count - lastPass.endIndex, privacy: .public) silent after)")
        } else {
            startIndex = min(press.samples.count, Int(press.committer.passStartSeconds * Self.sampleRate))
            let audio = Self.padToMinimum(Array(press.samples[startIndex...]))
            logger.info("Dictation release runs final pass (\(audio.count, privacy: .public) samples)")
            words = await transcribeWords(audio) ?? []
        }
        let remaining = press.committer.remainingWords(words: words, passStart: Double(startIndex) / Self.sampleRate)

        if !remaining.isEmpty {
            state = .inserting
            insertProgressive(remaining, press: press)
        }
        guard let lastInsertion = press.lastInsertion else {
            logger.info("Dictation transcription produced no text")
            lastOutcome = .failed(.emptyTranscript)
            return
        }
        lastOutcome = DictationOutcome(lastInsertion)
        logger.info("Dictation outcome: \(String(describing: lastInsertion), privacy: .public)")
    }

    static func isSilent(_ samples: ArraySlice<Float>) -> Bool {
        samples.allSatisfy { abs($0) < silencePeak }
    }

    /// Transcribes one progressive pass into words timed from the start of `samples`.
    private func transcribeWords(_ samples: [Float]) async -> [WordTiming]? {
#if DEBUG
        if let hook = progressivePassHookForTesting {
            return await hook(samples)
        }
#endif
        guard let asr = pressAsrManager, !samples.isEmpty else { return nil }
        do {
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(Self.padToMinimum(samples), decoderState: &decoderState)
            return buildWordTimings(from: result.tokenTimings ?? [])
        } catch {
            logger.error("ASR error: \(error.localizedDescription)")
            return nil
        }
    }
}
