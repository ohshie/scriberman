import Foundation

actor ModelInstallService {
    private let workspaceService: WorkspaceService

    init(workspaceService: WorkspaceService) {
        self.workspaceService = workspaceService
    }

    func installedModelGroups() -> [String] {
        []
    }

    func ensureWorkspaceWriteAccess() async throws -> Workspace {
        try await workspaceService.requireWritableWorkspace()
    }
}
