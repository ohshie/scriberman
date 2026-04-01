import Foundation

protocol WorkspaceServiceProtocol {
    func currentWorkspace() async -> Workspace?
    func requireWritableWorkspace() async throws -> Workspace
}
