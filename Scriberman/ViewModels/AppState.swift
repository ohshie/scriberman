import CoreAudio
import Foundation
import Observation

enum OnboardingStep: Int, CaseIterable {
    case screenRecording
    case microphone
    case workspace
    case models
    /// Optional: can be answered with "Not now". Shown once, after the required steps.
    case calendar
}

@Observable
@MainActor
final class AppState {
    let mainServices: MainServiceContainer
    let backgroundServices: BackgroundServiceContainer
    let permissionService: PermissionServiceProtocol
    let newSessionViewModel: NewSessionViewModel
    let jobsViewModel: JobsViewModel
    let settingsViewModel: SettingsViewModel
    let updateService: UpdateService
    let menuBarSettings: MenuBarSettings
    let appAudioSettings: AppAudioSettings
    let idlePromptPreferences = IdlePromptPreferences()
    let appIconPreferences = AppIconPreferences()
    private let restoreWorkspaceHandler: () async throws -> Workspace
    private let setWorkspaceHandler: (URL) async throws -> Workspace

    @ObservationIgnored private var readinessTask: Task<Void, Never>?
    private var preparedWorkspace: Workspace?
    private var hasRegisteredHotkey = false
    private var isChangingWorkspace = false
    private let prepareDictationHandler: ((Workspace) async -> Void)?
    private let registerHotkeyHandler: (() -> Void)?

    let dictationService: DictationService
    let hotkeyRegistrar = HotkeyRegistrar()
    let dictationHotkeySettings = DictationHotkeySettings()
    let dictationModeSettings: DictationModeSettings
    let asrProcessorSettings = AsrProcessorSettings()
    @ObservationIgnored let dictationHUD = DictationHUDController()
    let calendarSuggestions: CalendarSuggestionController
    /// True from presenting the calendar step until it is answered in this launch.
    private(set) var isCalendarInvitationActive = false

    var pendingSession: PendingSession?
    /// The Settings tab a request to open Settings was actually asking for, or `nil` for whichever
    /// was last shown. Set by the places that send people to Settings for one specific thing.
    var requestedSettingsTab: SettingsTab?
    var sessionToTrim: RecordingSession?
    private var shouldFocusPendingSessionFromMenuBar = false
    private(set) var workspace: Workspace?
    private(set) var workspaceErrorMessage: String?
    var isBootstrapping = true

    var requiredOnboardingStep: OnboardingStep? {
        if permissionService.screenRecordingStatus != .granted {
            return .screenRecording
        }

        if permissionService.micStatus != .granted {
            return .microphone
        }

        if workspace == nil {
            return .workspace
        }

        if settingsViewModel.bundlePhase != .allReady {
            return .models
        }

        if isCalendarInvitationActive
            || (!calendarSuggestions.preferences.invitationShown && !isCaptureActive) {
            return .calendar
        }

        return nil
    }

    var aiProviderService: AIProviderService {
        mainServices.aiProviderService
    }

    var audioDeviceService: AudioDeviceService {
        mainServices.audioDeviceService
    }

    var appAudioService: AppAudioService {
        mainServices.appAudioService
    }

    convenience init() {
        self.init(services: .live())
    }

    init(
        services: ServiceContainer,
        updateService: UpdateService? = nil,
        restoreWorkspaceHandler: (() async throws -> Workspace)? = nil,
        setWorkspaceHandler: ((URL) async throws -> Workspace)? = nil,
        prepareDictationHandler: ((Workspace) async -> Void)? = nil,
        registerHotkeyHandler: (() -> Void)? = nil
    ) {
        self.prepareDictationHandler = prepareDictationHandler
        self.registerHotkeyHandler = registerHotkeyHandler
        self.mainServices = services.main
        self.backgroundServices = services.background
        self.permissionService = services.main.permissionService
        self.updateService = updateService ?? .live()
        self.restoreWorkspaceHandler = restoreWorkspaceHandler ?? {
            try await services.background.workspaceService.restoreWorkspaceIfPossible()
        }
        self.setWorkspaceHandler = setWorkspaceHandler ?? { url in
            try await services.background.workspaceService.setWorkspace(url: url)
        }
        self.newSessionViewModel = NewSessionViewModel(
            workspaceService: services.background.workspaceService,
            recordingService: services.background.recordingService,
            audioDeviceService: services.main.audioDeviceService,
            appAudioService: services.main.appAudioService,
            screenCaptureService: services.main.screenCaptureService,
            permissionService: services.main.permissionService,
            speakerEmbeddingStore: services.background.speakerEmbeddingStore
        )
        self.jobsViewModel = JobsViewModel(
            workspaceService: services.background.workspaceService,
            transcriptionService: services.background.transcriptionService,
            retranscriptionService: services.background.retranscriptionService,
            audioImportService: services.background.audioImportService,
            transcriptExportService: services.main.transcriptExportService
        )
        self.settingsViewModel = SettingsViewModel(
            workspaceService: services.background.workspaceService,
            modelInstallService: services.background.modelInstallService,
            speakerEmbeddingStore: services.background.speakerEmbeddingStore,
            appAudioSettings: services.main.appAudioSettings
        )
        self.menuBarSettings = MenuBarSettings()
        self.appAudioSettings = services.main.appAudioSettings
        self.newSessionViewModel.idlePromptPreferencesProvider = { [idlePromptPreferences] in
            idlePromptPreferences.settings
        }
        let dictationModeSettings = DictationModeSettings()
        self.dictationModeSettings = dictationModeSettings
        self.dictationService = DictationService(
            recordingService: services.background.recordingService,
            mode: { dictationModeSettings.mode }
        )
        self.newSessionViewModel.menuBarSettings = self.menuBarSettings
        self.newSessionViewModel.settingsViewModel = self.settingsViewModel
        self.jobsViewModel.settingsViewModel = self.settingsViewModel
        self.calendarSuggestions = CalendarSuggestionController(
            service: services.main.calendarService,
            preferences: services.main.calendarPreferences
        )
    }

    /// Recording or dictation in progress. Calendar suggestions are hidden while this is true.
    var isCaptureActive: Bool {
        if !newSessionViewModel.isIdle {
            return true
        }
        switch dictationService.state {
        case .listening, .transcribing, .inserting:
            return true
        case .idle, .prewarming:
            return false
        }
    }

    // MARK: - Calendar suggestions

    /// Records the calendar step as shown when it appears, so quitting before answering does
    /// not bring it back. The step stays up for this launch until answered.
    func markCalendarInvitationPresented() {
        guard !calendarSuggestions.preferences.invitationShown else { return }
        calendarSuggestions.preferences.invitationShown = true
        isCalendarInvitationActive = true
    }

    /// Answers the calendar step. Enabling waits for the permission result; the step completes
    /// either way.
    func resolveCalendarInvitation(enable: Bool) async {
        if enable {
            await calendarSuggestions.setEnabled(true)
        }
        isCalendarInvitationActive = false
    }

    enum CalendarPreparationResult: Equatable {
        case prepared
        /// A draft exists; the user must confirm replacing its title.
        case needsTitleReplacement(draftID: UUID, meetingTitle: String)
        /// The meeting is no longer eligible, or capture is active. Nothing changed.
        case unavailable
    }

    /// Prepares a draft named after the meeting, after re-checking the meeting against a fresh
    /// query. Never starts capture.
    func prepareCalendarSession(_ occurrenceID: CalendarOccurrenceID) async -> CalendarPreparationResult {
        guard let suggestion = await calendarSuggestions.validatedSuggestion(occurrenceID),
              !isCaptureActive else {
            return .unavailable
        }
        if let draft = pendingSession {
            return .needsTitleReplacement(draftID: draft.id, meetingTitle: sessionTitle(for: suggestion))
        }
        selectPendingSession()
        pendingSession?.title = sessionTitle(for: suggestion)
        calendarSuggestions.markPrepared(occurrenceID)
        return .prepared
    }

    /// Replaces the title of the draft the user confirmed for, keeping its capture selections.
    /// Everything is re-checked because the meeting, the draft or capture may have changed while
    /// the confirmation was open.
    func confirmCalendarTitleReplacement(
        _ occurrenceID: CalendarOccurrenceID,
        draftID: UUID
    ) async -> CalendarPreparationResult {
        guard let suggestion = await calendarSuggestions.validatedSuggestion(occurrenceID),
              !isCaptureActive,
              pendingSession?.id == draftID else {
            return .unavailable
        }
        pendingSession?.title = sessionTitle(for: suggestion)
        calendarSuggestions.markPrepared(occurrenceID)
        return .prepared
    }

    private func sessionTitle(for suggestion: CalendarMeetingSuggestion) -> String {
        let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? Self.defaultPendingSessionTitle() : title
    }

    func selectPendingSession() {
        if pendingSession == nil {
            newSessionViewModel.reset()
            pendingSession = PendingSession(title: Self.defaultPendingSessionTitle())
        }
    }

    func discardPendingSession() {
        pendingSession = nil
        if case .recording = newSessionViewModel.state {
            return
        }
        newSessionViewModel.reset()
    }

    func requestPendingSessionFocusFromMenuBar() {
        shouldFocusPendingSessionFromMenuBar = true
    }

    func consumePendingSessionFocusRequest() -> Bool {
        let shouldFocus = shouldFocusPendingSessionFromMenuBar
        shouldFocusPendingSessionFromMenuBar = false
        return shouldFocus
    }

    func bootstrapWorkspace() async {
        defer { isBootstrapping = false }

        do {
            let restoredWorkspace = try await restoreWorkspaceHandler()
            workspace = restoredWorkspace
            workspaceErrorMessage = nil
        } catch WorkspaceError.notConfigured {
            workspace = nil
            workspaceErrorMessage = nil
        } catch {
            workspace = nil
            workspaceErrorMessage = error.localizedDescription
        }

        // Before anything that can load the batch diarizer (recovery sweep, retranscription).
        if workspace != nil {
            do {
                try await backgroundServices.modelInstallService.clearStaging()
            } catch {
                workspaceErrorMessage = error.localizedDescription
            }
            await backgroundServices.modelInstallService.stampDiarizerRevisionIfMissing()
        }

        permissionService.checkAll()
        _ = await permissionService.verifyMic()
        _ = await permissionService.verifyScreenRecording()

        await settingsViewModel.refresh()

        if workspace != nil {
            let recovery = backgroundServices.recoveryService
            Task { await recovery.sweepIncompleteSessions() }
        }

        applyReadiness()
    }

    func applyReadiness() {
        if requiredOnboardingStep == nil, workspace != nil {
            calendarSuggestions.activate()
        }
        guard requiredOnboardingStep == nil, let workspace,
              preparedWorkspace != workspace else { return }
        preparedWorkspace = workspace
        readinessTask?.cancel()
        dictationService.prepare(for: workspace)
        readinessTask = Task { [dictationService, prepareDictationHandler] in
            if let prepareDictationHandler {
                await prepareDictationHandler(workspace)
            } else {
                await dictationService.prewarm(workspace: workspace)
            }
        }
        if !hasRegisteredHotkey {
            hasRegisteredHotkey = true
            if let registerHotkeyHandler {
                registerHotkeyHandler()
            } else {
                wireHotkeyRegistrar()
            }
        }
    }

    /// Stores the processor and reloads dictation's model on it. Recordings and
    /// batch jobs pick it up on their next load.
    func setAsrProcessor(_ processor: AsrProcessor) {
        guard processor != asrProcessorSettings.processor else { return }
        asrProcessorSettings.setProcessor(processor)
        guard requiredOnboardingStep == nil, let workspace else { return }
        Task { [dictationService] in
            await dictationService.prewarm(workspace: workspace)
        }
    }

    var isWorkspaceChangeAllowed: Bool {
        guard !isChangingWorkspace, newSessionViewModel.isIdle,
              dictationService.state == .idle || dictationService.state == .prewarming,
              !jobsViewModel.isImporting, !jobsViewModel.isRetranscribing else { return false }
        switch settingsViewModel.bundlePhase {
        case .downloading, .warmingUp: return false
        default: return true
        }
    }

    private func wireHotkeyRegistrar() {
        hotkeyRegistrar.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, requiredOnboardingStep == nil, !isChangingWorkspace else { return }
                dictationHUD.show(for: dictationService)
                let deviceID = audioDeviceService.availableDevices.first {
                    $0.uid == menuBarSettings.lastUsedMicUID
                }?.id
                await dictationService.start(deviceID: deviceID)
            }
        }
        hotkeyRegistrar.onKeyUp = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await dictationService.stop()
            }
        }
        hotkeyRegistrar.register(combo: dictationHotkeySettings.combo)
    }

    func selectWorkspace(url: URL) async {
        guard isWorkspaceChangeAllowed else { return }
        isChangingWorkspace = true
        defer { isChangingWorkspace = false }
        do {
            let configuredWorkspace = try await setWorkspaceHandler(url)
            settingsViewModel.bundlePhase = .idle
            workspace = configuredWorkspace
            workspaceErrorMessage = nil
            await backgroundServices.modelInstallService.stampDiarizerRevisionIfMissing()
        } catch {
            workspaceErrorMessage = error.localizedDescription
            return
        }

        await settingsViewModel.refresh()
        applyReadiness()
    }

    func verifyWorkspaceForWrite() async -> Bool {
        do {
            let writableWorkspace = try await backgroundServices.workspaceService.requireAuthorizedWorkspace()
            workspace = writableWorkspace
            workspaceErrorMessage = nil
            return true
        } catch {
            workspace = nil
            workspaceErrorMessage = error.localizedDescription
            return false
        }
    }

    func refreshPermissionsOnActivation() async {
        permissionService.checkAll()
        _ = await permissionService.verifyMic()
        _ = await permissionService.verifyScreenRecording()
    }

    private static func defaultPendingSessionTitle(referenceDate: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Session \(formatter.string(from: referenceDate))"
    }
}
