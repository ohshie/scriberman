import Foundation

/// The hidden folder at a workspace's root where deleted sessions wait until they are restored or
/// removed for good.
///
/// Each held session is one subfolder named by its session `id`: the session's original folder,
/// moved here whole, with its snapshot inside. Moving keeps the files on the same volume, so
/// holding and releasing are renames.
struct HoldingFolder: Equatable {
    enum HoldingError: LocalizedError {
        case notASessionFolder(URL)
        case originalPathOccupied(URL)

        var errorDescription: String? {
            switch self {
            case .notASessionFolder(let url):
                "Refusing to hold a folder outside the workspace's session areas: \(url.path)"
            case .originalPathOccupied(let url):
                "Something already exists at the session's original path: \(url.path)"
            }
        }
    }

    static let name = ".pending-deletions"

    let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var url: URL {
        workspace.rootURL.appendingPathComponent(Self.name, isDirectory: true)
    }

    func heldFolder(for sessionID: UUID) -> URL {
        url.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Moves `folder` into holding as the subfolder for `sessionID`.
    ///
    /// Refuses anything that is not a session folder of this workspace: the input is a path from
    /// the store.
    func hold(_ folder: URL, sessionID: UUID) throws {
        guard JobsViewModel.isRemovableSessionFolder(folder, in: workspace) else {
            throw HoldingError.notASessionFolder(folder)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder, to: heldFolder(for: sessionID))
    }

    /// Moves the held subfolder for `sessionID` back to `folder`, refusing when `folder` exists.
    func release(sessionID: UUID, to folder: URL) throws {
        guard JobsViewModel.isRemovableSessionFolder(folder, in: workspace) else {
            throw HoldingError.notASessionFolder(folder)
        }
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            throw HoldingError.originalPathOccupied(folder)
        }
        try FileManager.default.moveItem(at: heldFolder(for: sessionID), to: folder)
    }

    /// The snapshots of every held session, in no particular order. A subfolder without a readable
    /// snapshot, or whose snapshot names another session, is left out.
    func heldSnapshots() -> [SessionSnapshot] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.compactMap { name in
            guard let sessionID = UUID(uuidString: name),
                  let snapshot = try? SessionSnapshot.read(from: heldFolder(for: sessionID)),
                  snapshot.sessionID == sessionID else {
                return nil
            }
            return snapshot
        }
    }

    /// Removes the held subfolder for `sessionID` for good. One that is already gone counts as
    /// removed.
    func remove(sessionID: UUID) throws {
        do {
            try FileManager.default.removeItem(at: heldFolder(for: sessionID))
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
    }
}
