import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    let mainServices: MainServiceContainer
    let backgroundServices: BackgroundServiceContainer
    let permissionService: PermissionServiceProtocol
    let newSessionViewModel: NewSessionViewModel
    let jobsViewModel: JobsViewModel
    let settingsViewModel: SettingsViewModel
    private let restoreWorkspaceHandler: () async throws -> Workspace
    private let setWorkspaceHandler: (URL) async throws -> Workspace

    var pendingSession: PendingSession?
    private(set) var workspace: Workspace?
    private(set) var workspaceErrorMessage: String?
    var workspaceSelectionRequired = false
    var showPermissionsOnboarding = false

    var aiProviderService: AIProviderService {
        mainServices.aiProviderService
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
        do {
            let restoredWorkspace = try await restoreWorkspaceHandler()
            workspace = restoredWorkspace
            workspaceErrorMessage = nil
            workspaceSelectionRequired = false
        } catch WorkspaceError.notConfigured {
            workspace = nil
            workspaceErrorMessage = nil
            workspaceSelectionRequired = true
        } catch {
            workspace = nil
            workspaceErrorMessage = error.localizedDescription
            workspaceSelectionRequired = true
        }

        await refreshPermissionPresentationState(strictVerification: true)

        await settingsViewModel.refresh()
    }

    func selectWorkspace(url: URL) async {
        do {
            let configuredWorkspace = try await setWorkspaceHandler(url)
            workspace = configuredWorkspace
            workspaceErrorMessage = nil
            workspaceSelectionRequired = false
            await refreshPermissionPresentationState(strictVerification: true)
        } catch {
            workspace = nil
            workspaceErrorMessage = error.localizedDescription
            workspaceSelectionRequired = true
            showPermissionsOnboarding = false
        }

        await settingsViewModel.refresh()
    }

    func verifyWorkspaceForWrite() async -> Bool {
        do {
            let writableWorkspace = try await backgroundServices.workspaceService.requireWritableWorkspace()
            workspace = writableWorkspace
            workspaceErrorMessage = nil
            workspaceSelectionRequired = false
            return true
        } catch {
            workspace = nil
            workspaceErrorMessage = error.localizedDescription
            workspaceSelectionRequired = true
            return false
        }
    }

    func refreshPermissionsOnActivation() async {
        await refreshPermissionPresentationState(strictVerification: true)
    }

    private static func defaultPendingSessionTitle(referenceDate: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Session \(formatter.string(from: referenceDate))"
    }

    private func refreshPermissionPresentationState(strictVerification: Bool) async {
        permissionService.checkAll()

        if strictVerification {
            _ = await permissionService.verifyMic()
            _ = await permissionService.verifyScreenRecording()
        }

        showPermissionsOnboarding = !workspaceSelectionRequired && permissionService.needsOnboarding
    }
}
