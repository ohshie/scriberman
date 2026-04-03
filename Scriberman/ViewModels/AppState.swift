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
    let menuBarSettings: MenuBarSettings
    private let restoreWorkspaceHandler: () async throws -> Workspace
    private let setWorkspaceHandler: (URL) async throws -> Workspace

    var pendingSession: PendingSession?
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
        restoreWorkspaceHandler: (() async throws -> Workspace)? = nil,
        setWorkspaceHandler: ((URL) async throws -> Workspace)? = nil
    ) {
        self.mainServices = services.main
        self.backgroundServices = services.background
        self.permissionService = services.main.permissionService
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
            speakerEmbeddingStore: services.background.speakerEmbeddingStore
        )
        self.menuBarSettings = MenuBarSettings()
        self.newSessionViewModel.menuBarSettings = self.menuBarSettings
    }

    func selectPendingSession() {
        if pendingSession == nil {
            newSessionViewModel.reset()
            pendingSession = PendingSession(title: Self.defaultPendingSessionTitle())
        }
    }

    func discardPendingSession() {
        pendingSession = nil
        newSessionViewModel.reset()
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
