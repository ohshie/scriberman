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
    private let startAccess: @Sendable (URL) -> Bool
    private let stopAccess: @Sendable (URL) -> Void
    private let createFolders: @Sendable (Workspace) throws -> Void
    private let createBookmark: @Sendable (URL) throws -> Data

    private var activeWorkspaceURL: URL?
    private var hasScopedAccess = false

    init(
        bookmarkStore: BookmarkStore,
        startAccess: @escaping @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        createFolders: @escaping @Sendable (Workspace) throws -> Void = { workspace in
            try FileManager.default.createDirectory(at: workspace.modelsURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace.jobsURL, withIntermediateDirectories: true)
        },
        createBookmark: @escaping @Sendable (URL) throws -> Data = { url in
            try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    ) {
        self.bookmarkStore = bookmarkStore
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        self.createFolders = createFolders
        self.createBookmark = createBookmark
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

        return try activateWorkspace(url: url, saveAuthorization: isStale)
    }

    func setWorkspace(url: URL) throws(WorkspaceError) -> Workspace {
        try activateWorkspace(url: url, saveAuthorization: true)
    }

    func currentWorkspace() async -> Workspace? {
        guard let activeWorkspaceURL, hasScopedAccess else {
            return nil
        }

        return Workspace(rootURL: activeWorkspaceURL)
    }

    func requireAuthorizedWorkspace() async throws(WorkspaceError) -> Workspace {
        guard let workspace = await currentWorkspace() else {
            throw WorkspaceError.notConfigured
        }

        guard startAccess(workspace.rootURL) else {
            throw WorkspaceError.accessDenied
        }

        stopAccess(workspace.rootURL)
        return workspace
    }

    private func activateWorkspace(url: URL, saveAuthorization: Bool) throws(WorkspaceError) -> Workspace {
        guard startAccess(url) else {
            throw WorkspaceError.accessDenied
        }
        var committed = false
        defer { if !committed { stopAccess(url) } }
        let workspace = Workspace(rootURL: url)
        do {
            try createFolders(workspace)
        } catch {
            throw WorkspaceError.failedToCreateSubfolders
        }
        if saveAuthorization {
            try saveBookmark(for: url)
        }
        releaseActiveWorkspaceIfNeeded()
        activeWorkspaceURL = url
        hasScopedAccess = true
        committed = true
        return workspace
    }

    private func saveBookmark(for url: URL) throws(WorkspaceError) {
        let bookmarkData: Data

        do {
            bookmarkData = try createBookmark(url)
        } catch {
            throw WorkspaceError.failedToCreateBookmark
        }

        bookmarkStore.saveWorkspaceBookmark(bookmarkData)
    }

    private func releaseActiveWorkspaceIfNeeded() {
        guard let activeWorkspaceURL, hasScopedAccess else {
            return
        }

        stopAccess(activeWorkspaceURL)
        hasScopedAccess = false
        self.activeWorkspaceURL = nil
    }
}
