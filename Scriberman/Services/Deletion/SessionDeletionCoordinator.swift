import Accessibility
import Foundation
import OSLog
import SwiftData

/// Owns every delete and restore of a session, for every window.
///
/// The main window is a `WindowGroup`, so several windows, each with its own undo manager and
/// selection, can act on one session. Per-window code cannot keep them from racing; this one
/// object does, by running the operations on each session one after another.
///
/// A delete does not destroy anything. It writes a snapshot of the record into the session's
/// folder, moves the folder into the workspace's holding folder and deletes the record. Undo moves
/// the folder back and inserts a record built from the snapshot.
@MainActor
final class SessionDeletionCoordinator {
    static let deletedAnnouncement = "Session deleted"
    static let restoredAnnouncement = "Session restored"

    /// Keeps a removal observer registered for as long as it is retained.
    final class RemovalObservation {
        fileprivate let handler: @MainActor (UUID) -> Void

        fileprivate init(handler: @escaping @MainActor (UUID) -> Void) {
            self.handler = handler
        }
    }

    /// The target of one deletion's undo and redo entries, so a failed operation removes exactly
    /// those entries and nothing else on the stack.
    private final class DeletionUndoTarget {
        let sessionID: UUID

        init(sessionID: UUID) {
            self.sessionID = sessionID
        }
    }

    /// A session this run deleted and still holds: where, and which undo entries can restore it.
    private struct Hold {
        let workspace: Workspace
        let target: DeletionUndoTarget
        weak var undoManager: UndoManager?
    }

    private struct WeakObservation {
        weak var observation: RemovalObservation?
    }

    private let workspaceService: WorkspaceServiceProtocol
    private let tagService: TagService
    private let saveContext: @MainActor (ModelContext) throws -> Void
    private let now: @MainActor () -> Date
    private let announce: @MainActor (String) -> Void
    private let startAccess: @MainActor (URL) -> Bool
    private let stopAccess: @MainActor (URL) -> Void
    private let logger = Logger(subsystem: "Scriberman", category: "SessionDeletion")

    private var holds: [UUID: Hold] = [:]
    /// The last operation queued for each session, which the next one waits for.
    private var operations: [UUID: (token: UUID, tail: Task<Void, Never>)] = [:]
    private var removalObservations: [WeakObservation] = []

    init(
        workspaceService: WorkspaceServiceProtocol,
        tagService: TagService = TagService(),
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
        now: @escaping @MainActor () -> Date = { .now },
        announce: @escaping @MainActor (String) -> Void = SessionDeletionCoordinator.postAnnouncement,
        startAccess: @escaping @MainActor (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @MainActor (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.workspaceService = workspaceService
        self.tagService = tagService
        self.saveContext = saveContext
        self.now = now
        self.announce = announce
        self.startAccess = startAccess
        self.stopAccess = stopAccess
    }

    static func postAnnouncement(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// Calls `handler` with a session's `id` as it starts leaving the store — on delete and on redo
    /// — so a window can drop its selection and stop playback before the record goes.
    func observeRemovals(_ handler: @escaping @MainActor (UUID) -> Void) -> RemovalObservation {
        let observation = RemovalObservation(handler: handler)
        removalObservations.removeAll { $0.observation == nil }
        removalObservations.append(WeakObservation(observation: observation))
        return observation
    }

    /// Returns once every queued operation has finished.
    func waitUntilIdle() async {
        while let (_, tail) = operations.values.first {
            await tail.value
        }
    }

    // MARK: - Delete

    /// Holds `session` and deletes its record, then registers undo with `undoManager`.
    @discardableResult
    func delete(
        _ session: RecordingSession,
        context: ModelContext,
        undoManager: UndoManager?
    ) async -> JobsViewModel.DeletionResult {
        let sessionID = session.id
        return await enqueue(sessionID) { [self] in
            // A second window's delete of the same session, queued behind the first.
            guard session.modelContext != nil, !session.isDeleted else {
                logger.notice("Skipped deleting a session that is already deleted.")
                return .deleted
            }
            notifyRemoval(of: sessionID)
            let (result, workspace) = await hold(session, context: context)
            guard result == .deleted, let workspace else { return result }
            let target = DeletionUndoTarget(sessionID: sessionID)
            holds[sessionID] = Hold(workspace: workspace, target: target, undoManager: undoManager)
            if let undoManager {
                undoManager.beginUndoGrouping()
                registerUndo(of: target, context: context, undoManager: undoManager)
                undoManager.endUndoGrouping()
            }
            announce(Self.deletedAnnouncement)
            return .deleted
        }.value
    }

    /// Snapshot, move into holding, delete the record and save, rolling back what was done when a
    /// step fails. Returns the workspace the session is held in when it worked.
    private func hold(
        _ session: RecordingSession,
        context: ModelContext
    ) async -> (JobsViewModel.DeletionResult, Workspace?) {
        guard let workspace = await workspaceService.currentWorkspace() else {
            logger.error("Refusing to delete a session with no workspace available.")
            return (.moveFailed, nil)
        }
        let isScoped = startAccess(workspace.rootURL)
        defer { if isScoped { stopAccess(workspace.rootURL) } }

        let sessionID = session.id
        let folder = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        guard JobsViewModel.isRemovableSessionFolder(folder, in: workspace) else {
            logger.error("Refusing to delete a session whose folder is outside the workspace: \(folder.path, privacy: .public)")
            return (.moveFailed, nil)
        }
        let holding = HoldingFolder(workspace: workspace)

        do {
            try SessionSnapshot(recording: session, originalFolder: folder, deletedAt: now()).write(into: folder)
            try holding.hold(folder, sessionID: sessionID)
        } catch {
            logger.error("Could not hold session folder \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            removeSnapshot(from: folder)
            return (.moveFailed, nil)
        }

        context.delete(session)
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            logger.error("Deleting a session failed to save: \(error.localizedDescription, privacy: .public)")
            do {
                try holding.release(sessionID: sessionID, to: folder)
                removeSnapshot(from: folder)
            } catch {
                logger.error(
                    "Could not move session folder back from holding; it stays held with its snapshot: \(holding.heldFolder(for: sessionID).path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            return (.saveFailed(error.localizedDescription), nil)
        }
        return (.deleted, workspace)
    }

    // MARK: - Restore

    /// Moves the held folder back and inserts its record. Returns whether it worked.
    private func restore(_ target: DeletionUndoTarget, context: ModelContext) async -> Bool {
        let sessionID = target.sessionID
        guard let hold = holds[sessionID], hold.target === target else {
            logger.notice("Skipped restoring a session this undo entry no longer holds.")
            return false
        }
        guard await workspaceService.currentWorkspace() == hold.workspace else {
            logger.notice("Skipped restoring a session held in a workspace that is not active.")
            return false
        }
        let workspace = hold.workspace
        let isScoped = startAccess(workspace.rootURL)
        defer { if isScoped { stopAccess(workspace.rootURL) } }

        let holding = HoldingFolder(workspace: workspace)
        let snapshot: SessionSnapshot
        do {
            snapshot = try SessionSnapshot.read(from: holding.heldFolder(for: sessionID))
        } catch {
            logger.error("Could not read the snapshot of a held session: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard case .recording(let record) = snapshot.session else { return false }
        let folder = URL(fileURLWithPath: snapshot.originalFolderPath)

        // Before anything is inserted: seeding the default tag saves the context.
        let tags: [RecordingTag]
        do {
            tags = try restorableTags(record.tagIDs, in: context)
        } catch {
            logger.error("Could not look up a restored session's tags: \(error.localizedDescription, privacy: .public)")
            return false
        }

        do {
            try holding.release(sessionID: sessionID, to: folder)
        } catch {
            logger.error("Could not move a held session back: \(error.localizedDescription, privacy: .public)")
            return false
        }

        let session = record.insertRecording(into: context)
        session.tags = tags
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            logger.error("Restoring a session failed to save: \(error.localizedDescription, privacy: .public)")
            do {
                try holding.hold(folder, sessionID: sessionID)
            } catch {
                logger.error(
                    "Could not move a session folder back into holding; it stays at its path with its snapshot: \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            return false
        }

        removeSnapshot(from: folder)
        holds[sessionID] = nil
        return true
    }

    /// The tags in `ids` that still exist, in order, or the default tag when none do.
    private func restorableTags(_ ids: [UUID], in context: ModelContext) throws -> [RecordingTag] {
        // In memory, as `TagService` does for the same relationship.
        let existing = Dictionary(
            try context.fetch(FetchDescriptor<RecordingTag>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let tags = ids.compactMap { existing[$0] }
        return tags.isEmpty ? [try tagService.seedDefaultTagIfNeeded(in: context)] : tags
    }

    // MARK: - Undo and redo

    /// Registers restoring the session held for `target`. Undoing registers the redo first, so the
    /// Edit menu is right at once, then queues the restore; a failed restore removes the redo.
    private func registerUndo(of target: DeletionUndoTarget, context: ModelContext, undoManager: UndoManager) {
        // The handler holds the target and the coordinator: the undo manager retains neither, and
        // `holds` lets go of the target once the session is restored.
        undoManager.registerUndo(withTarget: target) { [weak undoManager] _ in
            guard let undoManager else { return }
            self.registerRedo(of: target, context: context, undoManager: undoManager)
            self.enqueue(target.sessionID) {
                if await self.restore(target, context: context) {
                    self.announce(Self.restoredAnnouncement)
                } else {
                    undoManager.removeAllActions(withTarget: target)
                    self.logger.error("Undoing a delete failed; the session stays deleted.")
                }
            }
        }
        undoManager.setActionName(UndoActionName.deleteSession)
    }

    /// Registers deleting the restored session again. Redoing registers the undo first, then queues
    /// the delete; a failed delete removes the undo.
    private func registerRedo(of target: DeletionUndoTarget, context: ModelContext, undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: target) { [weak undoManager] _ in
            guard let undoManager else { return }
            self.registerUndo(of: target, context: context, undoManager: undoManager)
            let sessionID = target.sessionID
            self.enqueue(sessionID) {
                guard let session = try? RecordingSession.fetch(id: sessionID, in: context) else {
                    undoManager.removeAllActions(withTarget: target)
                    self.logger.notice("Skipped redoing a delete: the session is not in the store.")
                    return
                }
                self.notifyRemoval(of: sessionID)
                let (result, workspace) = await self.hold(session, context: context)
                if result == .deleted, let workspace {
                    self.holds[sessionID] = Hold(workspace: workspace, target: target, undoManager: undoManager)
                    self.announce(Self.deletedAnnouncement)
                } else {
                    undoManager.removeAllActions(withTarget: target)
                    self.logger.error("Redoing a delete failed; the session stays restored.")
                }
            }
        }
        undoManager.setActionName(UndoActionName.deleteSession)
    }

    // MARK: - Helpers

    /// Queues `operation` behind every operation already queued for `sessionID`. Queued at once,
    /// so an undo handler's operation is in the queue when the handler returns.
    @discardableResult
    private func enqueue<Result: Sendable>(
        _ sessionID: UUID,
        _ operation: @escaping @MainActor () async -> Result
    ) -> Task<Result, Never> {
        let previous = operations[sessionID]?.tail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        let token = UUID()
        let tail = Task { @MainActor [weak self] in
            _ = await task.value
            if self?.operations[sessionID]?.token == token {
                self?.operations[sessionID] = nil
            }
        }
        operations[sessionID] = (token, tail)
        return task
    }

    private func notifyRemoval(of sessionID: UUID) {
        removalObservations.removeAll { $0.observation == nil }
        for observation in removalObservations.compactMap(\.observation) {
            observation.handler(sessionID)
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
