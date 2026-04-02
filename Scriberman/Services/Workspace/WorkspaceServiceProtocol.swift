import Foundation

protocol WorkspaceServiceProtocol: Sendable {
    func currentWorkspace() async -> Workspace?
    func requireWritableWorkspace() async throws(WorkspaceError) -> Workspace
}
