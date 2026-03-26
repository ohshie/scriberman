import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    private let workspaceService: WorkspaceService
    private let modelInstallService: ModelInstallService

    init(workspaceService: WorkspaceService, modelInstallService: ModelInstallService) {
        self.workspaceService = workspaceService
        self.modelInstallService = modelInstallService
    }

    func refresh() async {
        async let workspace = workspaceService.currentWorkspace()
        async let models = modelInstallService.installedModelGroups()
        _ = await (workspace, models)
    }
}
