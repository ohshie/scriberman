import Foundation
@testable import Scriberman

final class MockWorkspaceService: WorkspaceServiceProtocol {
    var currentWorkspaceResult: Workspace?
    var requireWritableResult: Result<Workspace, Error> = .failure(MockWorkspaceServiceError.notConfigured)

    func currentWorkspace() async -> Workspace? {
        currentWorkspaceResult
    }

    func requireWritableWorkspace() async throws -> Workspace {
        try requireWritableResult.get()
    }
}

enum MockWorkspaceServiceError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No workspace configured"
        }
    }
}
