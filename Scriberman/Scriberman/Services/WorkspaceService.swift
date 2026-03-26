import Foundation

actor WorkspaceService {
    private let bookmarkStore: BookmarkStore

    init(bookmarkStore: BookmarkStore) {
        self.bookmarkStore = bookmarkStore
    }

    func currentWorkspace() -> Workspace? {
        guard bookmarkStore.loadWorkspaceBookmark() != nil else { return nil }
        return nil
    }
}
