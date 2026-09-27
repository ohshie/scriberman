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
    @ObservationIgnored private let loadAsr: @Sendable (Workspace) async throws -> AsrManager
    // Single-flight pre-warm (design D4): callers with the same key join
    // this task; a failed load clears it so the next call retries.
    @ObservationIgnored private var prewarmLoad: (key: PrewarmKey, task: Task<Void, Never>)?

    private var preparedWorkspace: Workspace?

    private struct PrewarmKey: Equatable {
        let workspaceRoot: URL
        let modelRevision: String
    }

    @ObservationIgnored private let captureSession: any DictationCapturing
    @ObservationIgnored private let insertText: @MainActor (String) -> InsertionOutcome
    @ObservationIgnored private let recordingService: any RecordingServiceProtocol

    // Serialization (design D3): stop() awaits the in-flight start before
    // touching the session, so a quick press-release cannot interleave and
    // strand the service in .listening.
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var levelHandlerInstalled = false

#if DEBUG
    @ObservationIgnored var transcribeHookForTesting: (@Sendable ([Float]) async -> String?)?
#endif

    init(
        recordingService: any RecordingServiceProtocol,
        captureSession: any DictationCapturing = DictationCaptureSession(),
        insertText: @escaping @MainActor (String) -> InsertionOutcome = { TextInjector().insert($0) },
        loadAsr: @escaping @Sendable (Workspace) async throws -> AsrManager = DictationService.loadWorkspaceAsr
    ) {
        self.recordingService = recordingService
        self.captureSession = captureSession
        self.insertText = insertText
        self.loadAsr = loadAsr
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
        let key = PrewarmKey(workspaceRoot: workspace.rootURL, modelRevision: "\(ModelPathResolver.asrModelVersion)")
        if let prewarmLoad, prewarmLoad.key == key {
            await prewarmLoad.task.value
            return
        }

        if state == .idle {
            state = .prewarming
        }
        let loadAsr = loadAsr
        // The task body updates state itself, so every caller awaiting it
        // resumes with the load already applied.
        let task = Task { [weak self] in
            do {
                let asr = try await loadAsr(workspace)
                guard !Task.isCancelled else { return }
                self?.asrManager = asr
                self?.logger.info("DictationService pre-warm complete")
            } catch {
                guard !Task.isCancelled else { return }
                self?.logger.warning("DictationService pre-warm failed (non-fatal): \(error.localizedDescription)")
                self?.asrManager = nil
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

    nonisolated static func loadWorkspaceAsr(_ workspace: Workspace) async throws -> AsrManager {
        let asrDir = try ModelPathResolver().modelDirectory(for: .asrParakeetUltra, in: workspace)
        let asr = AsrManager(config: ASRConfig())
        let asrModels = try await AsrModels.load(from: asrDir, version: ModelPathResolver.asrModelVersion, encoderComputeUnits: .cpuAndGPU)
        try await asr.loadModels(asrModels)
        return asr
    }

    // MARK: - Lifecycle

    func start(deviceID: AudioDeviceID?) async {
        guard state == .idle || state == .prewarming, startTask == nil else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            // A press during pre-warm waits for that load (design D4).
            await self.prewarmLoad?.task.value
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

        do {
            let stream = try await captureSession.start(deviceID: deviceID)
            state = .listening
            startProcessing(stream: stream)
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
        let hasModel = asrManager != nil || transcribeHookForTesting != nil
#else
        let hasModel = asrManager != nil
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
        guard let asr = asrManager, !samples.isEmpty else { return nil }
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
}
