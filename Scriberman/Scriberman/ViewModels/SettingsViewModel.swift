import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    private let workspaceService: WorkspaceService
    private let modelInstallService: ModelInstallService

    @Published var workspacePathText: String = "Not configured"
    @Published var workspaceStatusText: String = "Select a workspace to enable model installs."

    init(workspaceService: WorkspaceService, modelInstallService: ModelInstallService) {
        self.workspaceService = workspaceService
        self.modelInstallService = modelInstallService
    }

    func refresh() async {
        let workspaceValue = await workspaceService.currentWorkspace()
        _ = await modelInstallService.installedModelGroups()

        if let workspaceValue {
            workspacePathText = workspaceValue.rootURL.path
            workspaceStatusText = "Workspace is configured and accessible."
        } else {
            workspacePathText = "Not configured"
            workspaceStatusText = "Select a workspace to enable model installs."
        }
    }
}
