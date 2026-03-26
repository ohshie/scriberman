import Foundation

@MainActor
final class JobsViewModel: ObservableObject {
    private let workspaceService: WorkspaceService

    init(workspaceService: WorkspaceService) {
        self.workspaceService = workspaceService
    }

    func refresh() async {
        _ = await workspaceService.currentWorkspace()
    }
}
