import Foundation
import OSLog
import SwiftData

/// Brings one workspace's held sessions and the store back into agreement after a crash, then
/// removes the held sessions whose restore deadline has passed.
///
/// The snapshot file marks a delete or restore in progress, so every interrupted operation leaves
/// one behind: in a held subfolder, or in a session folder of `recordings/` or `imports/`. Each is
/// checked against the store by its session `id`. A held session whose record still exists is
/// never treated as deleted, and a held subfolder without a readable snapshot is never removed.
///
/// The sweep only moves folders and removes snapshot files and expired held subfolders; it never
/// writes to the store.
@MainActor
struct HeldSessionSweep {
    struct Result {
        /// Committed deletions still within their restore period.
        var held: [SessionSnapshot] = []
        /// Sessions whose held folder the sweep removed for good.
        var removed: [UUID] = []
        /// Sessions the sweep found were never deleted: their record exists.
        var notDeleted: [UUID] = []
    }

    let holding: HoldingFolder
    let context: ModelContext
    let now: Date
    let holdDuration: TimeInterval
    private let logger = Logger(subsystem: "Scriberman", category: "SessionDeletion")

    init(workspace: Workspace, context: ModelContext, now: Date, holdDuration: TimeInterval) {
        self.holding = HoldingFolder(workspace: workspace)
        self.context = context
        self.now = now
        self.holdDuration = holdDuration
    }

    private var workspace: Workspace { holding.workspace }

    /// Reconciles first, so only committed deletions reach the expiry step.
    func run() -> Result {
        var result = Result()
        reconcileSessionFolders(into: &result)
        let committed = reconcileHeldFolders(into: &result)
        for snapshot in committed {
            guard snapshot.deletedAt.addingTimeInterval(holdDuration) <= now else {
                result.held.append(snapshot)
                continue
            }
            do {
                try holding.remove(sessionID: snapshot.sessionID)
                result.removed.append(snapshot.sessionID)
            } catch {
                logger.error("Could not remove an expired held session: \(holding.heldFolder(for: snapshot.sessionID).path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }

    // MARK: - Reconcile

    /// Session folders with a snapshot in them: a crash before the move into holding, a restore
    /// that crashed before removing the snapshot, or a restore that crashed before its save.
    private func reconcileSessionFolders(into result: inout Result) {
        for folder in subfolders(of: workspace.recordingsURL) + subfolders(of: workspace.importsURL)
        where SessionSnapshot.exists(in: folder) {
            let snapshot: SessionSnapshot
            do {
                snapshot = try SessionSnapshot.read(from: folder)
            } catch {
                logger.error("Left a session folder with an unreadable snapshot as it is: \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            switch recordExists(snapshot.sessionID) {
            case nil:
                continue
            case true?:
                removeSnapshot(from: folder)
                result.notDeleted.append(snapshot.sessionID)
            case false?:
                do {
                    try holding.hold(folder, sessionID: snapshot.sessionID)
                    logger.notice("Moved a session folder left by an interrupted restore back into holding: \(folder.path, privacy: .public)")
                } catch {
                    logger.error("Could not move a session folder left by an interrupted restore back into holding: \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Every held subfolder. Returns the snapshots of the committed deletions among them.
    private func reconcileHeldFolders(into result: inout Result) -> [SessionSnapshot] {
        var committed: [SessionSnapshot] = []
        for held in subfolders(of: holding.url) {
            guard let sessionID = UUID(uuidString: held.lastPathComponent) else {
                logger.error("Left a held folder not named by a session id as it is: \(held.path, privacy: .public)")
                continue
            }
            let snapshot = try? SessionSnapshot.read(from: held)
            guard let snapshot, snapshot.sessionID == sessionID else {
                reconcileUnreadableHold(sessionID, into: &result)
                continue
            }
            switch recordExists(sessionID) {
            case nil:
                continue
            case true?:
                // The delete did not save: crash between the move and the save, or a failed move
                // back.
                result.notDeleted.append(sessionID)
                moveBack(sessionID, to: URL(fileURLWithPath: snapshot.originalFolderPath))
            case false?:
                committed.append(snapshot)
            }
        }
        return committed
    }

    /// A held subfolder without a readable snapshot goes back to its record's folder when its name
    /// matches a record, and is otherwise kept and logged.
    private func reconcileUnreadableHold(_ sessionID: UUID, into result: inout Result) {
        let held = holding.heldFolder(for: sessionID)
        let folder: URL?
        do {
            folder = try recordFolder(of: sessionID)
        } catch {
            logger.error("Could not look up a held session in the store: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let folder else {
            logger.error("Kept a held folder with no readable snapshot and no record: \(held.path, privacy: .public)")
            return
        }
        result.notDeleted.append(sessionID)
        moveBack(sessionID, to: folder)
    }

    // MARK: - Helpers

    /// Moves a held subfolder back to `folder` and removes its snapshot. Refused, and left held,
    /// when `folder` is occupied.
    private func moveBack(_ sessionID: UUID, to folder: URL) {
        do {
            try holding.release(sessionID: sessionID, to: folder)
        } catch {
            logger.error("Could not move a held session whose record exists back; it stays held: \(holding.heldFolder(for: sessionID).path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        removeSnapshot(from: folder)
        logger.notice("Moved a held session whose record exists back: \(folder.path, privacy: .public)")
    }

    /// Whether the store has a record for `sessionID`, of either kind, or `nil` when the store
    /// could not be read. Nothing is done to a session whose record cannot be checked.
    private func recordExists(_ sessionID: UUID) -> Bool? {
        do {
            return try RecordingSession.fetch(id: sessionID, in: context) != nil
                || ImportedSession.fetch(id: sessionID, in: context) != nil
        } catch {
            logger.error("Could not look up a held session in the store: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The folder of the record for `sessionID`, or `nil` when there is no record or it has no
    /// folder.
    private func recordFolder(of sessionID: UUID) throws -> URL? {
        if let session = try RecordingSession.fetch(id: sessionID, in: context) {
            return URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        }
        if let session = try ImportedSession.fetch(id: sessionID, in: context) {
            return session.mixdownURL.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        }
        return nil
    }

    private func subfolders(of url: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.compactMap { name in
            let folder = url.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return folder
        }
    }

    private func removeSnapshot(from folder: URL) {
        do {
            try SessionSnapshot.remove(from: folder)
        } catch {
            logger.error("Could not remove the snapshot in \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
