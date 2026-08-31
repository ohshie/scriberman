import CoreAudio
import Foundation
import Observation

enum OnboardingStep: Int, CaseIterable {
    case screenRecording
    case microphone
    case workspace
    case models
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

    let dictationService: DictationService
    let hotkeyRegistrar = HotkeyRegistrar()
    let dictationHotkeySettings = DictationHotkeySettings()
    @ObservationIgnored let dictationHUD = DictationHUDController()

    var pendingSession: PendingSession?
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
        setWorkspaceHandler: ((URL) async throws -> Workspace)? = nil
    ) {
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
        self.dictationService = DictationService(recordingService: services.background.recordingService)
        self.newSessionViewModel.menuBarSettings = self.menuBarSettings
        self.newSessionViewModel.settingsViewModel = self.settingsViewModel
        self.jobsViewModel.settingsViewModel = self.settingsViewModel
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

        permissionService.checkAll()
        _ = await permissionService.verifyMic()
        _ = await permissionService.verifyScreenRecording()

        await settingsViewModel.refresh()

        if workspace != nil {
            let recovery = backgroundServices.recoveryService
            Task { await recovery.sweepIncompleteSessions() }
        }

        if requiredOnboardingStep == nil, let workspace {
            await dictationService.prewarm(workspace: workspace)
            wireHotkeyRegistrar()
        }
    }

    private func wireHotkeyRegistrar() {
        hotkeyRegistrar.onKeyDown = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
        do {
            let configuredWorkspace = try await setWorkspaceHandler(url)
            workspace = configuredWorkspace
            workspaceErrorMessage = nil
        } catch {
            workspace = nil
            workspaceErrorMessage = error.localizedDescription
        }

        await settingsViewModel.refresh()
    }

    func verifyWorkspaceForWrite() async -> Bool {
        do {
            let writableWorkspace = try await backgroundServices.workspaceService.requireWritableWorkspace()
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
