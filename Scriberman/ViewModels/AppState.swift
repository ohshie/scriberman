import Foundation

@MainActor
final class AppState: ObservableObject {
    enum Tab: Hashable {
        case studio
        case jobs
        case settings
    }

    let services: ServiceContainer
    let permissionService: PermissionServiceProtocol
    let studioViewModel: StudioViewModel
    let jobsViewModel: JobsViewModel
    let settingsViewModel: SettingsViewModel

    @Published var selectedTab: Tab = .studio {
        didSet {
            if selectedTab == .studio {
                studioViewModel.refreshApps()
            }
        }
    }
    @Published private(set) var workspace: Workspace?
    @Published private(set) var workspaceErrorMessage: String?
    @Published var workspaceSelectionRequired = false
    @Published var showPermissionsOnboarding = false

    convenience init() {
        self.init(services: .live())
    }

    init(services: ServiceContainer) {
        self.services = services
        self.permissionService = services.permissionService
        self.studioViewModel = StudioViewModel(
            workspaceService: services.workspaceService,
            recordingService: services.recordingService,
            audioDeviceService: services.audioDeviceService,
            appAudioService: services.appAudioService,
            permissionService: services.permissionService
        )
        self.jobsViewModel = JobsViewModel(
            workspaceService: services.workspaceService,
            transcriptionService: services.transcriptionService
        )
        self.settingsViewModel = SettingsViewModel(
            workspaceService: services.workspaceService,
            modelInstallService: services.modelInstallService
        )
        self.studioViewModel.onSessionStopped = { [weak self] _ in
            self?.studioViewModel.clearStoppedCTAIfNeeded()
            self?.selectedTab = .jobs
        }
    }

    func selectTab(_ tab: Tab) {
        if tab != .studio {
            studioViewModel.clearStoppedCTAIfNeeded()
        } else {
            studioViewModel.refreshApps()
        }
        selectedTab = tab
    }

    func bootstrapWorkspace() async {
        do {
            let restoredWorkspace = try await services.workspaceService.restoreWorkspaceIfPossible()
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
            let configuredWorkspace = try await services.workspaceService.setWorkspace(url: url)
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
}
