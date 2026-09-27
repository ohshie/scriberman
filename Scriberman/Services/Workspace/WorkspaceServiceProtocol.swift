import Foundation

protocol WorkspaceServiceProtocol: Sendable {
    func currentWorkspace() async -> Workspace?
    func requireAuthorizedWorkspace() async throws(WorkspaceError) -> Workspace
}
