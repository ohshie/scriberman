import Foundation

protocol BookmarkStore {
    func loadWorkspaceBookmark() -> Data?
    func saveWorkspaceBookmark(_ data: Data)
}

final class UserDefaultsBookmarkStore: BookmarkStore {
    private let key = "workspace.bookmark"

    func loadWorkspaceBookmark() -> Data? {
        UserDefaults.standard.data(forKey: key)
    }

    func saveWorkspaceBookmark(_ data: Data) {
        UserDefaults.standard.set(data, forKey: key)
    }
}
