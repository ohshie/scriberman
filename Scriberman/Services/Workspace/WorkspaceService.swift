import Foundation

enum WorkspaceError: LocalizedError {
    case notConfigured
    case accessDenied
    case invalidBookmark
    case failedToCreateBookmark
    case failedToCreateSubfolders

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No workspace is configured."
        case .accessDenied:
            return "The selected workspace is no longer accessible. Please re-authorize it."
        case .invalidBookmark:
            return "Saved workspace authorization is invalid. Please select the workspace again."
        case .failedToCreateBookmark:
            return "Failed to save workspace authorization bookmark."
        case .failedToCreateSubfolders:
            return "Failed to initialize workspace folders."
        }
    }
}

actor WorkspaceService: WorkspaceServiceProtocol {
    private let bookmarkStore: BookmarkStore
    private let fileManager = FileManager.default

    private var activeWorkspaceURL: URL?
    private var hasScopedAccess = false

    init(bookmarkStore: BookmarkStore) {
        self.bookmarkStore = bookmarkStore
    }

    func restoreWorkspaceIfPossible() throws(WorkspaceError) -> Workspace {
        guard let bookmarkData = bookmarkStore.loadWorkspaceBookmark() else {
            throw WorkspaceError.notConfigured
        }

        var isStale = false
        let url: URL

        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw WorkspaceError.invalidBookmark
        }

        let workspace = try activateWorkspace(url: url)

        if isStale {
            try saveBookmark(for: workspace.rootURL)
        }

        return workspace
    }

    func setWorkspace(url: URL) throws(WorkspaceError) -> Workspace {
        let workspace = try activateWorkspace(url: url)
        try saveBookmark(for: workspace.rootURL)
        return workspace
    }

    func currentWorkspace() async -> Workspace? {
        guard let activeWorkspaceURL, hasScopedAccess else {
            return nil
        }

        return Workspace(rootURL: activeWorkspaceURL)
    }

    func requireWritableWorkspace() async throws(WorkspaceError) -> Workspace {
        guard let workspace = await currentWorkspace() else {
            throw WorkspaceError.notConfigured
        }

        guard workspace.rootURL.startAccessingSecurityScopedResource() else {
            throw WorkspaceError.accessDenied
        }

        workspace.rootURL.stopAccessingSecurityScopedResource()
        return workspace
    }

    private func activateWorkspace(url: URL) throws(WorkspaceError) -> Workspace {
        releaseActiveWorkspaceIfNeeded()

        guard url.startAccessingSecurityScopedResource() else {
            throw WorkspaceError.accessDenied
        }

        hasScopedAccess = true
        activeWorkspaceURL = url

        let workspace = Workspace(rootURL: url)

        do {
            try initializeWorkspaceFolders(workspace)
        } catch {
            releaseActiveWorkspaceIfNeeded()
            throw WorkspaceError.failedToCreateSubfolders
        }

        return workspace
    }

    private func initializeWorkspaceFolders(_ workspace: Workspace) throws(WorkspaceError) {
        do {
            try fileManager.createDirectory(at: workspace.modelsURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workspace.jobsURL, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.failedToCreateSubfolders
        }
    }

    private func saveBookmark(for url: URL) throws(WorkspaceError) {
        let bookmarkData: Data

        do {
            bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw WorkspaceError.failedToCreateBookmark
        }

        bookmarkStore.saveWorkspaceBookmark(bookmarkData)
    }

    private func releaseActiveWorkspaceIfNeeded() {
        guard let activeWorkspaceURL, hasScopedAccess else {
            return
        }

        activeWorkspaceURL.stopAccessingSecurityScopedResource()
        hasScopedAccess = false
        self.activeWorkspaceURL = nil
    }
}
