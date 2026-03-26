import Foundation

@MainActor
final class AppState: ObservableObject {
    let services: ServiceContainer
    let studioViewModel: StudioViewModel
    let jobsViewModel: JobsViewModel
    let settingsViewModel: SettingsViewModel

    @Published private(set) var workspace: Workspace?
    @Published private(set) var workspaceErrorMessage: String?
    @Published var workspaceSelectionRequired = false

    init(services: ServiceContainer = .live()) {
        self.services = services
        self.studioViewModel = StudioViewModel(
            workspaceService: services.workspaceService,
            recordingService: services.recordingService
        )
        self.jobsViewModel = JobsViewModel(workspaceService: services.workspaceService)
        self.settingsViewModel = SettingsViewModel(
            workspaceService: services.workspaceService,
            modelInstallService: services.modelInstallService
        )
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

        await settingsViewModel.refresh()
    }

    func selectWorkspace(url: URL) async {
        do {
            let configuredWorkspace = try await services.workspaceService.setWorkspace(url: url)
            workspace = configuredWorkspace
            workspaceErrorMessage = nil
            workspaceSelectionRequired = false
        } catch {
            workspace = nil
            workspaceErrorMessage = error.localizedDescription
            workspaceSelectionRequired = true
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
