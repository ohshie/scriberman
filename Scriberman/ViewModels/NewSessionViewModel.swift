import CoreAudio
import CoreGraphics
import Foundation
import OSLog
import Observation
import SwiftData

@MainActor
@Observable
final class NewSessionViewModel {
    enum State {
        case idle
        case recording(duration: TimeInterval, level: Float)
    }

    private let workspaceService: WorkspaceServiceProtocol
    private let recordingService: RecordingServiceProtocol
    private let audioDeviceService: AudioDeviceServiceProtocol
    private let appAudioService: AppAudioServiceProtocol
    private let screenCaptureService: ScreenCaptureServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let liveTranscriptionService: LiveTranscriptionService
    private var recordingMonitorTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    // MARK: - Idle session prompt

    /// True while the "Still in progress. Stop?" prompt should be on screen.
    var isIdlePromptVisible = false
    /// Supplies the current persisted idle-prompt settings. Injected at composition time so
    /// changes in Settings take effect on the next monitor tick.
    var idlePromptPreferencesProvider: (() -> IdlePromptSettings)?
    /// Settings used for evaluation; falls back to the shipped defaults when no provider is set.
    var idlePromptSettings: IdlePromptSettings {
        idlePromptPreferencesProvider?() ?? .default
    }
    private var idlePromptMachine = IdlePromptStateMachine()
    private var captureHealthMonitor = CaptureHealthMonitor()
    /// When capture health was last evaluated. The recording monitor ticks every 50 ms for the
    /// level meters; sampling frame counts that often would mean twenty extra actor hops a second
    /// for a check that only needs to be as fine-grained as the stall threshold.
    private var lastCaptureHealthEvaluationAt: Date?
    private let userInputIdleProvider: any UserInputIdleProviding
    /// True when this session captures both mic and app audio (the only case the prompt applies to).
    private var isIdlePromptApplicable = false
    private var activeRecordingSessionID: UUID?
    private let fileManager = FileManager.default
    var menuBarSettings: MenuBarSettings?
    var settingsViewModel: SettingsViewModel?

    var state: State = .idle
    // Separate wave inputs (design D4): the mic wave must not bounce when
    // only app audio is loud, so views get each source's level individually.
    private(set) var micAudioLevel: Float = 0
    private(set) var appAudioLevel: Float = 0
    var isIdle: Bool {
        if case .idle = state {
            return true
        }

        return false
    }
    var liveSegments: [TranscriptSegment] = []
    var errorMessage: String?
    /// Set when a recording was stopped because it never started writing audio. The UI observes
    /// this to present the failure; the wording is owned by the view, not by this model.
    var didFailToStartRecording = false
    private var startVerificationTask: Task<Void, Never>?
    private let sessionFailureLogWriter = SessionFailureLogWriter()
    private let logger = Logger(subsystem: "Scriberman", category: "NewSessionViewModel")
    var availableDevices: [AudioInputDevice] {
        audioDeviceService.availableDevices
    }
    var selectedDevice: AudioInputDevice? {
        get { audioDeviceService.selectedDevice }
        set {
            audioDeviceService.selectedDevice = newValue
            let desiredUID = newValue?.uid
            Task { [weak self] in
                await self?.retargetRecordingMicIfNeeded(desiredDeviceUID: desiredUID)
            }
        }
    }
    var runningApps: [CapturedApp] {
        appAudioService.runningApps
    }
    var availableDisplays: [CaptureDisplay] {
        screenCaptureService.availableDisplays
    }
    var selectedApp: CapturedApp? {
        get { appAudioService.selectedApp }
        set {
            appAudioService.selectedApp = newValue
        }
    }
    var selectedDisplayID: CGDirectDisplayID? {
        get { screenCaptureService.selectedDisplayID }
        set { screenCaptureService.selectedDisplayID = newValue }
    }
    var selectedDisplay: CaptureDisplay? {
        guard let selectedDisplayID else {
            return nil
        }
        return availableDisplays.first(where: { $0.displayID == selectedDisplayID })
    }
    private var screenRecordingStatus: PermissionStatus {
        permissionService.screenRecordingStatus
    }
    private var micStatus: PermissionStatus {
        permissionService.micStatus
    }
    var recordAppAudio: Bool = false {
        didSet {
            guard oldValue != recordAppAudio else {
                return
            }
            if recordAppAudio {
                guard screenRecordingPermissionGranted else {
                    recordAppAudio = false
                    requestScreenRecordingPermission()
                    return
                }
                restoreLastUsedApp()
            } else {
                selectedApp = nil
            }
        }
    }
    var recordScreen: Bool = false {
        didSet {
            guard oldValue != recordScreen else {
                return
            }
            if recordScreen {
                guard screenRecordingPermissionGranted else {
                    recordScreen = false
                    requestScreenRecordingPermission()
                    return
                }
                Task { [weak self] in
                    await self?.refreshAvailableDisplays()
                }
            }
        }
    }

    var appAudioToggleEnabled: Bool {
        true
    }

    var microphonePermissionGranted: Bool {
        micStatus == .granted
    }

    /// Reason shown on the microphone row's warning indicator; nil when access
    /// is granted (design D5).
    var micPermissionWarningText: String? {
        switch micStatus {
        case .granted:
            return nil
        case .notDetermined:
            return "Microphone access needed to record. Click to allow."
        case .denied:
            return "Microphone access is disabled. Click to open Privacy Settings."
        }
    }

    var micPermissionDenied: Bool {
        micStatus == .denied
    }

    /// Reason shown on the screen row's warning indicator; nil when screen
    /// recording permission is granted (design D5).
    var screenPermissionWarningText: String? {
        switch screenRecordingStatus {
        case .granted:
            return nil
        case .notDetermined:
            return "Screen Recording permission needed for app audio and screen capture. Click to allow."
        case .denied:
            return "Screen Recording is disabled. Click to open Privacy Settings."
        }
    }

    var screenPermissionDenied: Bool {
        screenRecordingStatus == .denied
    }

    var showAppPicker: Bool {
        recordAppAudio && screenRecordingStatus == .granted
    }

    var showDisplayPicker: Bool {
        recordScreen && screenRecordingStatus == .granted && availableDisplays.count > 1
    }

    var screenRecordingPermissionGranted: Bool {
        screenRecordingStatus == .granted
    }

    var canRecord: Bool {
        guard microphonePermissionGranted else {
            return false
        }
        if case .idle = state {
            if recordAppAudio && selectedApp == nil {
                return false
            }
            if recordScreen && effectiveCaptureDisplayID == nil {
                return false
            }
            return true
        }
        return false
    }

    init(
        workspaceService: WorkspaceServiceProtocol,
        recordingService: RecordingServiceProtocol,
        audioDeviceService: AudioDeviceServiceProtocol,
        appAudioService: AppAudioServiceProtocol,
        screenCaptureService: ScreenCaptureServiceProtocol,
        permissionService: PermissionServiceProtocol,
        speakerEmbeddingStore: SpeakerEmbeddingStore? = nil,
        userInputIdleProvider: any UserInputIdleProviding = SystemUserInputIdleProvider(),
        userDefaults _: UserDefaults = .standard
    ) {
        self.userInputIdleProvider = userInputIdleProvider
        self.liveTranscriptionService = LiveTranscriptionService(speakerEmbeddingStore: speakerEmbeddingStore)
        self.workspaceService = workspaceService
        self.recordingService = recordingService
        self.audioDeviceService = audioDeviceService
        self.appAudioService = appAudioService
        self.screenCaptureService = screenCaptureService
        self.permissionService = permissionService
        enforceAppAudioSelectionForCurrentPermissions()
    }

    func reset() {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        startVerificationTask?.cancel()
        startVerificationTask = nil
        if didFailToStartRecording {
            dismissRecordingStartFailure()
        }
        recordingStartedAt = nil
        activeRecordingSessionID = nil
        errorMessage = nil
        micAudioLevel = 0
        appAudioLevel = 0
        state = .idle
        dismissIdlePrompt()
        isIdlePromptApplicable = false
        idlePromptMachine = IdlePromptStateMachine()
        captureHealthMonitor = CaptureHealthMonitor(configuration: captureHealthConfiguration)
        lastCaptureHealthEvaluationAt = nil
        lastCaptureHealthEffect = .none
    }

    /// Tears the prompt down. Safe to call when it is not showing.
    private func dismissIdlePrompt() {
        guard isIdlePromptVisible else { return }
        isIdlePromptVisible = false
        onIdlePromptPresentationChanged?(false)
    }

    func refresh() async {
        _ = await workspaceService.currentWorkspace()
        await refreshAvailableDisplays()
    }

    func refreshApps() {
        appAudioService.refreshRunningApps()
    }

    func selectApp(_ app: CapturedApp?) {
        guard let app else {
            recordAppAudio = false
            return
        }

        guard screenRecordingPermissionGranted else {
            requestScreenRecordingPermission()
            return
        }

        selectedApp = app
        recordAppAudio = true
    }

    func refreshAudioDevicesOnAppear() {
        audioDeviceService.refreshDevices()
        Task {
            await recheckPermissions()
        }
        Task {
            await refreshAvailableDisplays()
        }
        // Pre-warm ASR + diarizer models when a workspace is available.
        Task {
            if let workspace = await workspaceService.currentWorkspace() {
                let pipelineConfig = settingsViewModel?.pipelineSettings ?? .defaults
                await liveTranscriptionService.prepare(workspace: workspace, config: pipelineConfig)
            }
        }
    }

    func refreshAudioDevicesOnPanelExpanded() {
        audioDeviceService.refreshDevices()
        Task {
            await recheckPermissions()
        }
        Task {
            await refreshAvailableDisplays()
        }
    }

    func requestMicrophonePermission() async {
        _ = await permissionService.requestMic()
    }

    func requestScreenRecordingPermission() {
        _ = permissionService.requestScreenRecording()
    }

    func recheckPermissions() async {
        permissionService.checkAll()
        _ = await permissionService.verifyMic()
        _ = await permissionService.verifyScreenRecording()
        enforceAppAudioSelectionForCurrentPermissions()
        await refreshAvailableDisplays()
    }

    func restoreLastUsedApp() {
        appAudioService.refreshRunningApps()
    }

    @discardableResult
    func startRecording(title: String, context: ModelContext) async -> RecordingSession? {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        if didFailToStartRecording {
            dismissRecordingStartFailure()
        }
        errorMessage = nil

        do {
            let workspace = try await workspaceService.requireWritableWorkspace()
            appAudioService.refreshRunningApps()

            var selectedCapturedAppName: String?
            var selectedAppProcessID: pid_t?
            let captureDisplayID = effectiveCaptureDisplayID

            if recordAppAudio, let selectedApp {
                selectedCapturedAppName = selectedApp.name
                selectedAppProcessID = selectedApp.pid
            }

            let selectedMicDeviceID = selectedDevice?.id
            var startError: Error?
            var recordingSessionID: UUID?
            var fallbackMessage: String?

            do {
                recordingSessionID = try await startRecordingAttempt(
                    in: workspace,
                    micDeviceID: selectedMicDeviceID,
                    captureDisplayID: captureDisplayID,
                    capturedAppName: selectedCapturedAppName,
                    appProcessID: selectedAppProcessID,
                    title: title
                )
            } catch {
                startError = error
            }

            if startError != nil, selectedAppProcessID != nil {
                fallbackMessage = "App audio capture unavailable. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording."

                do {
                    recordingSessionID = try await startRecordingAttempt(
                        in: workspace,
                        micDeviceID: selectedMicDeviceID,
                        captureDisplayID: captureDisplayID,
                        capturedAppName: nil,
                        appProcessID: nil,
                        title: title
                    )
                    startError = nil
                } catch {
                    startError = error
                }
            }

            if startError != nil, selectedMicDeviceID != nil {
                do {
                    recordingSessionID = try await startRecordingAttempt(
                        in: workspace,
                        micDeviceID: nil,
                        captureDisplayID: captureDisplayID,
                        capturedAppName: nil,
                        appProcessID: nil,
                        title: title
                    )
                    startError = nil
                    if fallbackMessage == nil {
                        fallbackMessage = "Selected microphone unavailable. Falling back to system default microphone."
                    }
                } catch {
                    startError = error
                }
            }

            if let startError {
                throw startError
            }
            guard let recordingSessionID else {
                throw RecordingError.failedToStart("Recording session could not be created.")
            }

            if let selectedDevice {
                audioDeviceService.incrementUsage(for: selectedDevice.uid)
            }

            if let selectedApp {
                appAudioService.incrementUsage(for: selectedApp.bundleID)
            }

            menuBarSettings?.lastUsedMicUID = selectedDevice?.uid
            menuBarSettings?.lastUsedAppBundleID = selectedApp?.bundleID

            if let fallbackMessage {
                errorMessage = fallbackMessage
            }

            recordingStartedAt = .now
            activeRecordingSessionID = recordingSessionID
            state = .recording(duration: 0, level: 0)
            liveSegments = []
            // The idle prompt only applies to mic + app sessions.
            isIdlePromptApplicable = selectedAppProcessID != nil
            idlePromptMachine = IdlePromptStateMachine()
            captureHealthMonitor = CaptureHealthMonitor(configuration: captureHealthConfiguration)
            lastCaptureHealthEvaluationAt = nil
            lastCaptureHealthEffect = .none
            isIdlePromptVisible = false

            // Scheduled here, immediately after capture started, and deliberately not after the
            // live-transcription start below. That start loads ASR and diarizer models and takes
            // an unbounded amount of time; sequencing verification behind it deferred the check by
            // that duration, which defeats catching a dead recording before anything worth keeping
            // was said.
            verifyRecordingStart(
                sessionID: recordingSessionID,
                workspace: workspace,
                context: context,
                captureStartedAt: recordingStartedAt ?? Date()
            )

            let descriptor = FetchDescriptor<RecordingSession>()
            let session = try? context.fetch(descriptor).first(where: { $0.id == recordingSessionID })
            
            // Start Live Transcription
            do {
                let pipelineConfig = settingsViewModel?.pipelineSettings ?? .defaults
                try await liveTranscriptionService.start(workspace: workspace, config: pipelineConfig)
                startLiveTranscriptionPipeline(context: context)
            } catch LiveTranscriptionError.initializationFailed {
                errorMessage = "Live transcription unavailable: Required models are missing. Open Settings → Models to install ASR and Speaker Diarization models."
            } catch {
                errorMessage = "Live transcription unavailable: \(error.localizedDescription)"
            }
            
            startRecordingMonitor(workspace: workspace, context: context)
            return session
        } catch {
            errorMessage = error.localizedDescription
            state = .idle
            return nil
        }
    }

    @discardableResult
    func startRecording(
        title: String,
        micDeviceUID: String?,
        app: CapturedApp?,
        context: ModelContext
    ) async -> RecordingSession? {
        audioDeviceService.refreshDevices()
        appAudioService.refreshRunningApps()

        if let micDeviceUID {
            selectedDevice = availableDevices.first(where: { $0.uid == micDeviceUID })
        } else {
            selectedDevice = nil
        }

        selectedApp = app
        recordAppAudio = app != nil
        recordScreen = false

        return await startRecording(title: title, context: context)
    }

    func stopRecording(context: ModelContext) async -> RecordingSession? {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        startVerificationTask?.cancel()
        startVerificationTask = nil

        let liveFinalSegments = await liveTranscriptionService.stop()
        let sessionID = await recordingService.stopRecording() ?? activeRecordingSessionID
        activeRecordingSessionID = nil
        // Tear the idle prompt down however the session ends (panel, UI button, menu bar,
        // app lifecycle), not just via reset().
        dismissIdlePrompt()
        isIdlePromptApplicable = false
        idlePromptMachine = IdlePromptStateMachine()
        captureHealthMonitor = CaptureHealthMonitor(configuration: captureHealthConfiguration)
        lastCaptureHealthEvaluationAt = nil
        lastCaptureHealthEffect = .none
        
        var fetchedSession: RecordingSession?
        if let sessionID = sessionID {
            let descriptor = FetchDescriptor<RecordingSession>()
            if let sessions = try? context.fetch(descriptor) {
                for session in sessions where session.id == sessionID {
                    fetchedSession = session
                    break
                }
            }
        }
        
        guard let session = fetchedSession else {
            state = .idle
            return nil
        }

        backfillPersistedSegments(liveFinalSegments, to: session, context: context)
        saveLiveTranscript(to: session)
        try? context.save()
        
        state = .idle
        return session
    }

    private func saveLiveTranscript(to session: RecordingSession) {
        let finalSegments = session.transcriptSegments
            .filter(\.isFinal)
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.createdAt < $1.createdAt
                }
                return $0.startTime < $1.startTime
            }
            .map {
                TranscriptSegment(
                    id: $0.id,
                    speakerId: $0.speakerId,
                    text: $0.text,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    audioSource: $0.audioSource,
                    isFinal: $0.isFinal
                )
            }
        
        if finalSegments.isEmpty {
            let transcript = Transcript(
                fullText: "",
                segments: [],
                speakers: []
            )
            session.transcript = transcript
            session.status = .done
            return
        }
        
        let speakerIds = Array(Set(finalSegments.map { $0.speakerId })).sorted()
        let speakers = speakerIds.enumerated().map { index, id in
            // "speaker_N" IDs come from the live diarizer; "unknown" is the fallback
            // when no diarizer match was found. Both map to a human-readable label.
            let isInternalId = id == "unknown" || id.hasPrefix("speaker_")
            return TranscriptSpeaker(
                id: id,
                label: isInternalId ? "Speaker \(index + 1)" : id,
                colorHex: "#007AFF"
            )
        }

        let transcript = Transcript(
            fullText: finalSegments.map { $0.text }.joined(separator: " "),
            segments: finalSegments,
            speakers: speakers
        )
        session.transcript = transcript
        session.status = .done
    }

    private func enforceAppAudioSelectionForCurrentPermissions() {
        guard screenRecordingStatus == .granted else {
            recordAppAudio = false
            recordScreen = false
            selectedApp = nil
            appAudioService.selectedApp = nil
            return
        }

        recordAppAudio = appAudioService.selectedApp != nil
    }

    private var effectiveCaptureDisplayID: CGDirectDisplayID? {
        guard recordScreen else {
            return nil
        }
        return selectedDisplayID
    }

    /// How long after a successful start to check that audio is actually being written.
    ///
    /// Long enough for the first buffers to land on both capture paths, short enough that a dead
    /// recording is caught before the user has said anything worth keeping.
    static let defaultStartVerificationDelay: Duration = .seconds(1)

    /// Overridable so tests can exercise the verify/retry sequence without waiting real seconds.
    var startVerificationDelay: Duration = NewSessionViewModel.defaultStartVerificationDelay

    /// How much of `delay` is left, measured from `start`. Zero once it has already elapsed.
    ///
    /// Pure so the anchoring is testable without a clock: the point of the verification delay is
    /// that it is counted from the moment capture started, not from whenever the checking task got
    /// around to running.
    static func remainingDelay(_ delay: Duration, since start: Date, now: Date) -> Duration {
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return delay }
        let remaining = delay - .seconds(elapsed)
        return remaining > .zero ? remaining : .zero
    }

    /// Verifies, one second after start, that frames are being written; restarts capture once if
    /// not; and fails the session if the restart does not help.
    ///
    /// Runs detached so the UI shows the recording immediately rather than stalling a second on a
    /// check that almost always passes.
    private func verifyRecordingStart(
        sessionID: UUID,
        workspace: Workspace,
        context: ModelContext,
        captureStartedAt: Date
    ) {
        startVerificationTask?.cancel()
        startVerificationTask = Task { [weak self] in
            guard let self else { return }

            // Anchored to when capture started, not to when this task happened to begin running,
            // so unrelated start-up work cannot push the check later.
            try? await Task.sleep(
                for: Self.remainingDelay(
                    startVerificationDelay,
                    since: captureStartedAt,
                    now: Date()
                )
            )
            guard !Task.isCancelled else { return }

            var counts = await recordingService.captureFrameCounts()
            if RecordingStartVerifier.verdict(micFrames: counts.mic, appFrames: counts.app) != .dead {
                return
            }

            logger.warning("Recording start verification found no frames written; restarting capture.")
            let didRestart = await recordingService.restartAudioCapture()

            if didRestart {
                try? await Task.sleep(for: startVerificationDelay)
                guard !Task.isCancelled else { return }
                counts = await recordingService.captureFrameCounts()
                if RecordingStartVerifier.verdict(micFrames: counts.mic, appFrames: counts.app) != .dead {
                    return
                }
            }

            await failRecordingStart(
                sessionID: sessionID,
                workspace: workspace,
                context: context,
                counts: counts,
                restartAttempted: didRestart
            )
        }
    }

    private func failRecordingStart(
        sessionID: UUID,
        workspace: Workspace,
        context: ModelContext,
        counts: (mic: Int64?, app: Int64?, micWriteFailures: Int, appWriteFailures: Int),
        restartAttempted: Bool
    ) async {
        let startedAt = recordingStartedAt ?? Date()
        let lastError = await recordingService.consumePendingError()?.localizedDescription

        sessionFailureLogWriter.write(
            SessionFailureLogWriter.Failure(
                sessionID: sessionID,
                startedAt: startedAt,
                micFrames: counts.mic,
                appFrames: counts.app,
                micWriteFailures: counts.micWriteFailures,
                appWriteFailures: counts.appWriteFailures,
                restartAttempted: restartAttempted,
                lastError: lastError
            ),
            in: workspace
        )

        _ = await recordingService.stopRecording()
        _ = await liveTranscriptionService.stop()
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        activeRecordingSessionID = nil
        recordingStartedAt = nil
        micAudioLevel = 0
        appAudioLevel = 0
        dismissIdlePrompt()
        isIdlePromptApplicable = false
        idlePromptMachine = IdlePromptStateMachine()
        captureHealthMonitor = CaptureHealthMonitor(configuration: captureHealthConfiguration)
        lastCaptureHealthEvaluationAt = nil
        lastCaptureHealthEffect = .none

        // Mark the session failed rather than deleting it: this reuses the status vocabulary the
        // jobs pipeline already uses for failures, and leaves the row to point at its log.
        let descriptor = FetchDescriptor<RecordingSession>()
        if let sessions = try? context.fetch(descriptor) {
            for session in sessions where session.id == sessionID {
                let reason = lastError ?? "Recording produced no audio."
                session.status = .error(reason)
                session.errorMessage = reason
                try? context.save()
                break
            }
        }

        state = .idle
        didFailToStartRecording = true
        onRecordingStartFailurePresentationChanged?(true)
    }

    /// Dismisses the failure panel. Nothing was captured, so there is no state to restore.
    func dismissRecordingStartFailure() {
        didFailToStartRecording = false
        onRecordingStartFailurePresentationChanged?(false)
    }

    private func startRecordingMonitor(workspace: Workspace, context: ModelContext) {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let isRecording = await recordingService.isRecording()
                guard isRecording else {
                    // `state = .idle` used to sit inside the `if let pendingError`, and
                    // `pendingError` was never assigned, so it was unreachable: capture ending
                    // behind the view model's back left the UI showing a recording forever.
                    if let pendingError = await recordingService.consumePendingError() {
                        errorMessage = pendingError.localizedDescription
                    }
                    state = .idle
                    break
                }

                let levels = await recordingService.audioLevels()
                micAudioLevel = levels.mic
                appAudioLevel = levels.app
                let startedAt = recordingStartedAt ?? .now
                let duration = Date().timeIntervalSince(startedAt)
                state = .recording(duration: duration, level: max(levels.mic, levels.app))

                await evaluateIdlePrompt(recordingStartedAt: startedAt)
                await evaluateCaptureHealth(workspace: workspace, context: context)

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Capture health

    /// How this view model configures `CaptureHealthMonitor`. Overridable so tests can exercise
    /// detection without waiting real seconds, mirroring `startVerificationDelay`.
    var captureHealthConfiguration: CaptureHealthMonitor.Configuration = .default

    /// How often capture health is evaluated. The recording monitor's own tick is 50 ms, which is
    /// what the level meters need and far finer than a stall threshold measured in seconds.
    var captureHealthEvaluationInterval: TimeInterval = 1

    /// The effect the monitor produced on its most recent evaluation. Observed by tests; while
    /// detection is observation-only this is also the only record of what it decided.
    private(set) var lastCaptureHealthEffect: CaptureHealthMonitor.Effect = .none

    /// Whether this recording's capture has been restarted at least once.
    var wasCaptureInterrupted: Bool { captureHealthMonitor.wasInterrupted }

    /// Whether a detected capture death is acted on, or only observed and logged.
    ///
    /// Overridable so tests can exercise both sides without touching user defaults.
    var isCaptureHealthRecoveryEnabled: Bool = AudioSyncConfig.isCaptureHealthRecoveryEnabled

    /// Set while a restart is in flight, so the 50 ms monitor loop cannot start a second one on top
    /// of it. Mirrors `RecordingService.isRecoveringMicCapture`.
    private var isRecoveringCapture = false

    /// Evaluates capture health at most once per `captureHealthEvaluationInterval`, and applies the
    /// resulting effect.
    private func evaluateCaptureHealth(workspace: Workspace, context: ModelContext) async {
        let now = Date()
        if let last = lastCaptureHealthEvaluationAt,
           now.timeIntervalSince(last) < captureHealthEvaluationInterval {
            return
        }
        lastCaptureHealthEvaluationAt = now

        guard !isRecoveringCapture else { return }

        let snapshot = await recordingService.captureHealthSnapshot()
        guard let sessionID = activeRecordingSessionID else {
            _ = captureHealthMonitor.update(now: now, snapshot: snapshot, isRecording: false)
            lastCaptureHealthEffect = .none
            return
        }
        let effect = captureHealthMonitor.update(now: now, snapshot: snapshot, isRecording: true)
        lastCaptureHealthEffect = effect

        guard effect != .none else { return }
        let mic = snapshot.micFrames.map(String.init) ?? "unavailable"
        let app = snapshot.appFrames.map(String.init) ?? "not captured"
        let failures = snapshot.streamFailureCount
        let restarts = captureHealthMonitor.restartsIssued

        guard isCaptureHealthRecoveryEnabled else {
            let action = effect == .restart ? "restart capture" : "stop the recording"
            logger.warning(
                "Capture health would \(action, privacy: .public) (recovery disabled). micFrames=\(mic, privacy: .public) appFrames=\(app, privacy: .public) streamFailures=\(failures, privacy: .public) restartsIssued=\(restarts, privacy: .public)"
            )
            return
        }

        switch effect {
        case .none:
            return
        case .restart:
            logger.warning(
                "Capture health restarting capture. micFrames=\(mic, privacy: .public) appFrames=\(app, privacy: .public) streamFailures=\(failures, privacy: .public) restartsIssued=\(restarts, privacy: .public)"
            )
            isRecoveringCapture = true
            let didRestart = await recordingService.restartAudioCaptureInPlace()
            isRecoveringCapture = false
            if !didRestart {
                // The monitor's budget still governs: a restart that would not start is simply not
                // a recovery, and the next evaluation counts it against the consecutive limit.
                logger.error("Capture restart did not take. Captured audio is retained.")
            }
        case .fail:
            logger.error(
                "Capture health stopping the recording; restarts exhausted. micFrames=\(mic, privacy: .public) appFrames=\(app, privacy: .public) streamFailures=\(failures, privacy: .public) restartsIssued=\(restarts, privacy: .public)"
            )
            await failRecordingAfterCaptureLoss(
                sessionID: sessionID,
                workspace: workspace,
                context: context,
                snapshot: snapshot
            )
        }
    }

    /// Ends a recording whose capture could not be recovered.
    ///
    /// Unlike a failed *start*, this recording captured audio, so it is finalized through the normal
    /// stop path rather than discarded: `stopRecording` closes the writers, writes the timing
    /// sidecars, and runs mixdown over everything that was captured on both sides of the outage.
    private func failRecordingAfterCaptureLoss(
        sessionID: UUID,
        workspace: Workspace,
        context: ModelContext,
        snapshot: CaptureHealthMonitor.Snapshot
    ) async {
        startVerificationTask?.cancel()
        startVerificationTask = nil

        let startedAt = recordingStartedAt ?? Date()
        let lastError = await recordingService.consumePendingError()
        sessionFailureLogWriter.write(
            SessionFailureLogWriter.Failure(
                sessionID: sessionID,
                startedAt: startedAt,
                micFrames: snapshot.micFrames,
                appFrames: snapshot.appFrames,
                micWriteFailures: 0,
                appWriteFailures: 0,
                restartAttempted: captureHealthMonitor.restartsIssued > 0,
                lastError: lastError?.diagnosticDetail ?? lastError?.localizedDescription
            ),
            in: workspace
        )

        _ = await stopRecording(context: context)
        didFailToStartRecording = true
        onRecordingStartFailurePresentationChanged?(true)
    }

    // MARK: - Idle session prompt

    /// Evaluates idleness once per monitor tick and applies the resulting effect.
    private func evaluateIdlePrompt(recordingStartedAt: Date) async {
        let timestamps = await recordingService.activityTimestamps()
        let now = Date()
        var userInput: Date?
        if idlePromptSettings.watchUserInput, let seconds = userInputIdleProvider.secondsSinceLastInput() {
            userInput = now.addingTimeInterval(-seconds)
        }

        let snapshot = IdleActivitySnapshot(
            appAudio: timestamps.app,
            micAudio: timestamps.mic,
            userInput: userInput
        )

        let effect = idlePromptMachine.update(
            now: now,
            snapshot: snapshot,
            settings: idlePromptSettings,
            recordingStartedAt: recordingStartedAt,
            isApplicable: isIdlePromptApplicable
        )

        switch effect {
        case .none:
            break
        case .showPrompt:
            isIdlePromptVisible = true
            onIdlePromptPresentationChanged?(true)
        case .dismissPrompt:
            isIdlePromptVisible = false
            onIdlePromptPresentationChanged?(false)
        case .autoStop:
            isIdlePromptVisible = false
            onIdlePromptPresentationChanged?(false)
            await stopFromIdlePrompt()
        }
    }

    /// Injected by the composition layer to show/hide the floating prompt panel.
    /// Presents or hides the "Recording failed." panel. Set by `AppDelegate`, which owns the
    /// panel; the view model owns only the fact that the start failed.
    var onRecordingStartFailurePresentationChanged: ((Bool) -> Void)?

    var onIdlePromptPresentationChanged: ((Bool) -> Void)?

    /// User chose a snooze duration on the prompt.
    func snoozeIdlePrompt(for duration: TimeInterval) {
        idlePromptMachine.snooze(for: duration, now: Date())
        isIdlePromptVisible = false
        onIdlePromptPresentationChanged?(false)
    }

    /// User chose "Stop & Save" on the prompt.
    func stopFromIdlePrompt() async {
        isIdlePromptVisible = false
        onIdlePromptPresentationChanged?(false)
        await onIdlePromptStopRequested?()
    }

    /// Injected by the composition layer to stop the recording through the normal path.
    var onIdlePromptStopRequested: (() async -> Void)?

    private func startRecordingAttempt(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        captureDisplayID: CGDirectDisplayID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws -> UUID {
        try await recordingService.startRecording(
            in: workspace,
            micDeviceID: micDeviceID,
            captureDisplayID: captureDisplayID,
            capturedAppName: capturedAppName,
            appProcessID: appProcessID,
            title: title
        )
    }

    private func refreshAvailableDisplays() async {
        guard screenRecordingPermissionGranted else {
            recordScreen = false
            return
        }
        await screenCaptureService.refreshAvailableDisplays()
    }

    private func retargetRecordingMicIfNeeded(desiredDeviceUID: String?) async {
        guard await recordingService.isRecording() else {
            return
        }
        await recordingService.retargetMic(desiredDeviceUID: desiredDeviceUID)
    }

    private func startLiveTranscriptionPipeline(context: ModelContext) {
        // Pipeline: buffers -> processor
        Task {
            for await (samples, source, sampleRate) in await recordingService.liveAudioStream() {
                await liveTranscriptionService.process(samples: samples, source: source, sampleRate: sampleRate)
            }
        }

        // Pipeline: results -> UI
        Task {
            for await segment in await liveTranscriptionService.transcriptStream {
                await MainActor.run {
                    updateLiveSegments(with: segment)
                    persistLiveTranscriptSegment(segment, context: context)
                }
            }
        }
    }

    private func persistLiveTranscriptSegment(_ segment: TranscriptSegment, context: ModelContext) {
        guard segment.isFinal, let sessionID = activeRecordingSessionID else {
            return
        }

        let descriptor = FetchDescriptor<RecordingSession>()
        guard let sessions = try? context.fetch(descriptor),
              let session = sessions.first(where: { $0.id == sessionID }),
              session.status == .recording
        else {
            return
        }

        if session.transcriptSegments.contains(where: { $0.id == segment.id }) {
            return
        }

        let persistedSegment = RecordingTranscriptSegment(segment: segment, session: session)
        context.insert(persistedSegment)
        try? context.save()
        appendSegmentToTranscriptMarkdown(persistedSegment, for: session)
    }

    private func backfillPersistedSegments(
        _ segments: [TranscriptSegment],
        to session: RecordingSession,
        context: ModelContext
    ) {
        let existingIDs = Set(session.transcriptSegments.map(\.id))
        let missingSegments = segments.filter { $0.isFinal && !existingIDs.contains($0.id) }

        for segment in missingSegments {
            let persistedSegment = RecordingTranscriptSegment(
                segment: segment,
                createdAt: Date(),
                session: session
            )
            context.insert(persistedSegment)
            appendSegmentToTranscriptMarkdown(persistedSegment, for: session)
        }
    }

    private func appendSegmentToTranscriptMarkdown(_ segment: RecordingTranscriptSegment, for session: RecordingSession) {
        appendTranscriptSegmentToMarkdown(segment, for: session, fileManager: fileManager)
    }

    private func updateLiveSegments(with segment: TranscriptSegment) {
        // 1. Retroactive speaker correction: a segment with this id already exists in
        //    liveSegments and the diarizer has now assigned it a real speaker.
        if let existingIndex = liveSegments.firstIndex(where: { $0.id == segment.id }) {
            liveSegments[existingIndex] = segment
            return
        }

        // 2. Rolling partial update: replace the last non-final segment from the same source.
        if let lastIndex = liveSegments.indices.last, !liveSegments[lastIndex].isFinal {
            if liveSegments[lastIndex].audioSource == segment.audioSource {
                liveSegments[lastIndex] = segment
                return
            }
        }

        // 3. New segment — append and cap the buffer.
        liveSegments.append(segment)
        if liveSegments.count > 100 {
            liveSegments.removeFirst(liveSegments.count - 100)
        }
    }
}
