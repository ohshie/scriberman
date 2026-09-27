import Foundation
@testable import Scriberman

final class MockWorkspaceService: WorkspaceServiceProtocol, @unchecked Sendable {
    var currentWorkspaceResult: Workspace?
    var requireWritableResult: Result<Workspace, WorkspaceError> = .failure(.notConfigured)

    func currentWorkspace() async -> Workspace? {
        currentWorkspaceResult
    }

    func requireAuthorizedWorkspace() async throws(WorkspaceError) -> Workspace {
        try requireWritableResult.get()
    }
}
