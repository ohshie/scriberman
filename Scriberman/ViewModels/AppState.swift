import Foundation

@MainActor
final class AppState: ObservableObject {
    let services: ServiceContainer
    let permissionService: PermissionServiceProtocol
    let newSessionViewModel: NewSessionViewModel
    let jobsViewModel: JobsViewModel
    let settingsViewModel: SettingsViewModel
    private let restoreWorkspaceHandler: () async throws -> Workspace
    private let setWorkspaceHandler: (URL) async throws -> Workspace

    @Published var pendingSession: PendingSession?
    @Published private(set) var workspace: Workspace?
    @Published private(set) var workspaceErrorMessage: String?
    @Published var workspaceSelectionRequired = false
    @Published var showPermissionsOnboarding = false

    var aiProviderService: AIProviderService {
        services.aiProviderService
    }

    convenience init() {
        self.init(services: .live())
    }

    init(
        services: ServiceContainer,
        restoreWorkspaceHandler: (() async throws -> Workspace)? = nil,
        setWorkspaceHandler: ((URL) async throws -> Workspace)? = nil
    ) {
        self.services = services
        self.permissionService = services.permissionService
        self.restoreWorkspaceHandler = restoreWorkspaceHandler ?? {
            try await services.workspaceService.restoreWorkspaceIfPossible()
        }
        self.setWorkspaceHandler = setWorkspaceHandler ?? { url in
            try await services.workspaceService.setWorkspace(url: url)
        }
        self.newSessionViewModel = NewSessionViewModel(
            workspaceService: services.workspaceService,
            recordingService: services.recordingService,
            audioDeviceService: services.audioDeviceService,
            appAudioService: services.appAudioService,
            permissionService: services.permissionService
        )
        self.jobsViewModel = JobsViewModel(
            workspaceService: services.workspaceService,
            transcriptionService: services.transcriptionService,
            retranscriptionService: services.retranscriptionService,
            audioImportService: services.audioImportService
        )
        self.settingsViewModel = SettingsViewModel(
            workspaceService: services.workspaceService,
            modelInstallService: services.modelInstallService
        )
    }

    func selectPendingSession() {
        if pendingSession == nil {
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

        permissionService.checkAll()
        showPermissionsOnboarding = !workspaceSelectionRequired && permissionService.needsOnboarding

        await settingsViewModel.refresh()
    }

    func selectWorkspace(url: URL) async {
        do {
            let configuredWorkspace = try await setWorkspaceHandler(url)
            workspace = configuredWorkspace
            workspaceErrorMessage = nil
            workspaceSelectionRequired = false
            permissionService.checkAll()
            showPermissionsOnboarding = permissionService.needsOnboarding
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
            let writableWorkspace = try await services.workspaceService.requireWritableWorkspace()
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

    private static func defaultPendingSessionTitle(referenceDate: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Session \(formatter.string(from: referenceDate))"
    }
}
