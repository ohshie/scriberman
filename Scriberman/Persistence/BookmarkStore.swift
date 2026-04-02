import Foundation

private let workspaceBookmarkKey = "workspace.bookmark"

protocol BookmarkStore: Sendable {
    func loadWorkspaceBookmark() -> Data?
    func saveWorkspaceBookmark(_ data: Data)
}

@MainActor
final class UserDefaultsBookmarkStore: BookmarkStore {
    nonisolated func loadWorkspaceBookmark() -> Data? {
        UserDefaults.standard.data(forKey: workspaceBookmarkKey)
    }

    nonisolated func saveWorkspaceBookmark(_ data: Data) {
        UserDefaults.standard.set(data, forKey: workspaceBookmarkKey)
    }
}
