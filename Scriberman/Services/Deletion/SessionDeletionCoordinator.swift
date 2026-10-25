import Accessibility
import Combine
import Foundation
import Observation
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
@Observable
final class SessionDeletionCoordinator {
    static let deletedAnnouncement = "Session deleted"
    static let restoredAnnouncement = "Session restored"
    /// How long a deleted session stays restorable before it is removed for good.
    static let holdDuration: TimeInterval = 24 * 60 * 60

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

    /// Changes after every operation on a held session, so a view listing them knows to read the
    /// holding folder again.
    @Observable
    final class HoldingChanges {
        fileprivate(set) var revision = 0
    }

    /// What removing a held session now did.
    enum RemovalResult: Equatable {
        case removed
        /// No workspace is active, so nothing was removed.
        case notHeld
        /// The held folder could not be removed; it is still on disk at this path.
        case folderLeft(URL)
    }

    private struct WeakObservation {
        weak var observation: RemovalObservation?
    }

    /// A session a delete can hold: a recording, or a settled imported session.
    private enum HeldSession {
        case recording(RecordingSession)
        case imported(ImportedSession)

        static func fetch(id: UUID, in context: ModelContext) throws -> HeldSession? {
            if let session = try RecordingSession.fetch(id: id, in: context) { return .recording(session) }
            if let session = try ImportedSession.fetch(id: id, in: context) { return .imported(session) }
            return nil
        }

        var id: UUID {
            switch self {
            case .recording(let session): session.id
            case .imported(let session): session.id
            }
        }

        var isInStore: Bool {
            switch self {
            case .recording(let session): session.modelContext != nil && !session.isDeleted
            case .imported(let session): session.modelContext != nil && !session.isDeleted
            }
        }

        /// The session's folder, or `nil` for an imported session with no mixdown.
        var folder: URL? {
            switch self {
            case .recording(let session):
                URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
            case .imported(let session):
                session.mixdownURL.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            }
        }

        func snapshot(originalFolder: URL, deletedAt: Date) -> SessionSnapshot {
            switch self {
            case .recording(let session):
                SessionSnapshot(recording: session, originalFolder: originalFolder, deletedAt: deletedAt)
            case .imported(let session):
                SessionSnapshot(imported: session, originalFolder: originalFolder, deletedAt: deletedAt)
            }
        }

        func delete(from context: ModelContext) {
            switch self {
            case .recording(let session): context.delete(session)
            case .imported(let session): context.delete(session)
            }
        }
    }

    private let workspaceService: WorkspaceServiceProtocol
    private let tagService: TagService
    private let saveContext: @MainActor (ModelContext) throws -> Void
    private let now: @MainActor () -> Date
    private let announce: @MainActor (String) -> Void
    private let startAccess: @MainActor (URL) -> Bool
    private let stopAccess: @MainActor (URL) -> Void
    private let scheduleExpiry: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable
    /// The session's background jobs, which a delete cancels and waits for before anything moves.
    let sessionJobs: SessionJobs
    private let logger = Logger(subsystem: "Scriberman", category: "SessionDeletion")

    private var holds: [UUID: Hold] = [:]
    /// The last operation queued for each session, which the next one waits for.
    private var operations: [UUID: (token: UUID, tail: Task<Void, Never>)] = [:]
    private var removalObservations: [WeakObservation] = []
    let holdingChanges = HoldingChanges()
    /// The pending expiry of each session this run holds. Replacing one cancels it.
    private var expiryTimers: [UUID: AnyCancellable] = [:]
    /// Sessions on their way out: off the list from the start of a delete, while their jobs stop.
    private var removingSessionIDs: Set<UUID> = []

    init(
        workspaceService: WorkspaceServiceProtocol,
        tagService: TagService = TagService(),
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() },
        now: @escaping @MainActor () -> Date = { .now },
        announce: @escaping @MainActor (String) -> Void = SessionDeletionCoordinator.postAnnouncement,
        startAccess: @escaping @MainActor (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: @escaping @MainActor (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        scheduleExpiry: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable
            = SessionDeletionCoordinator.schedule,
        sessionJobs: SessionJobs = SessionJobs()
    ) {
        self.workspaceService = workspaceService
        self.tagService = tagService
        self.saveContext = saveContext
        self.now = now
        self.announce = announce
        self.startAccess = startAccess
        self.stopAccess = stopAccess
        self.scheduleExpiry = scheduleExpiry
        self.sessionJobs = sessionJobs
    }

    /// Whether `sessionID` is being deleted: off the list while its jobs stop, before its record
    /// goes.
    func isRemoving(_ sessionID: UUID) -> Bool {
        removingSessionIDs.contains(sessionID)
    }

    static func postAnnouncement(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// Runs `action` on the main actor `delay` seconds from now, unless the returned value is
    /// cancelled first.
    static func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            action()
        }
        return AnyCancellable { task.cancel() }
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

    /// Whether deleting `session` holds it. An imported session that is still converting or
    /// transcribing, or has no mixdown (an import that has not finished or that failed), is deleted
    /// for good instead.
    static func canHold(_ session: ImportedSession) -> Bool {
        guard session.mixdownURL != nil else { return false }
        switch session.status {
        case .converting, .transcribing, .retranscribing: return false
        default: return true
        }
    }

    /// Holds `session` and deletes its record, then registers undo with `undoManager`.
    @discardableResult
    func delete(
        _ session: RecordingSession,
        context: ModelContext,
        undoManager: UndoManager?
    ) async -> JobsViewModel.DeletionResult {
        await delete(.recording(session), context: context, undoManager: undoManager)
    }

    /// Holds a settled imported session and deletes its record, then registers undo with
    /// `undoManager`. Refuses one that `canHold` rejects, deleting nothing.
    @discardableResult
    func delete(
        _ session: ImportedSession,
        context: ModelContext,
        undoManager: UndoManager?
    ) async -> JobsViewModel.DeletionResult {
        guard Self.canHold(session) else {
            logger.error("Refusing to hold an imported session that has not finished importing or transcribing.")
            return .moveFailed
        }
        return await delete(.imported(session), context: context, undoManager: undoManager)
    }

    /// Deletes an imported session the user confirmed deleting. Which way is decided now, so an
    /// import that settled while the confirmation was open is held; one still unfinished is
    /// deleted for good with its folder, with no undo.
    @discardableResult
    func deleteAfterConfirmation(
        _ session: ImportedSession,
        context: ModelContext,
        undoManager: UndoManager?
    ) async -> JobsViewModel.DeletionResult {
        if Self.canHold(session) {
            return await delete(.imported(session), context: context, undoManager: undoManager)
        }
        let sessionID = session.id
        return await enqueue(sessionID) { [self] in
            guard session.modelContext != nil, !session.isDeleted else {
                logger.notice("Skipped deleting a session that is already deleted.")
                return .deleted
            }
            notifyRemoval(of: sessionID)
            return await deletePermanently(session, context: context)
        }.value
    }

    /// Stops the import's jobs, deletes the record and saves, then removes the folder the import
    /// reported or its mixdown's folder. A failed import from an earlier run has neither, so its
    /// folder stays in `imports/`.
    private func deletePermanently(
        _ session: ImportedSession,
        context: ModelContext
    ) async -> JobsViewModel.DeletionResult {
        let sessionID = session.id
        removingSessionIDs.insert(sessionID)
        defer { removingSessionIDs.remove(sessionID) }
        await sessionJobs.cancelAndDrain(sessionID)

        let reportedFolder = sessionJobs.takeFolder(of: sessionID)
        let folder = reportedFolder
            ?? session.mixdownURL.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        context.delete(session)
        do {
            try saveContext(context)
        } catch {
            context.rollback()
            if let reportedFolder {
                sessionJobs.recordFolder(reportedFolder, of: sessionID)
            }
            logger.error("Deleting a session failed to save: \(error.localizedDescription, privacy: .public)")
            return .saveFailed(error.localizedDescription)
        }

        guard let folder else {
            logger.notice("Deleted an imported session with no known folder; anything it left stays in imports.")
            return .deleted
        }
        guard let workspace = await workspaceService.currentWorkspace() else {
            logger.error("Refusing to remove a session folder with no workspace available.")
            return .filesLeft(folder)
        }
        let isScoped = startAccess(workspace.rootURL)
        defer { if isScoped { stopAccess(workspace.rootURL) } }
        return JobsViewModel.removeSessionFolder(folder, in: workspace) ? .deleted : .filesLeft(folder)
    }

    private func delete(
        _ session: HeldSession,
        context: ModelContext,
        undoManager: UndoManager?
    ) async -> JobsViewModel.DeletionResult {
        let sessionID = session.id
        return await enqueue(sessionID) { [self] in
            // A second window's delete of the same session, queued behind the first.
            guard session.isInStore else {
                logger.notice("Skipped deleting a session that is already deleted.")
                return .deleted
            }
            notifyRemoval(of: sessionID)
            let (result, workspace) = await hold(session, context: context)
            guard result == .deleted, let workspace else { return result }
            let target = DeletionUndoTarget(sessionID: sessionID)
            holds[sessionID] = Hold(workspace: workspace, target: target, undoManager: undoManager)
            startExpiry(of: sessionID)
            if let undoManager {
                undoManager.beginUndoGrouping()
                registerUndo(of: target, context: context, undoManager: undoManager)
                undoManager.endUndoGrouping()
            }
            announce(Self.deletedAnnouncement)
            return .deleted
        }.value
    }

    /// Stop the session's jobs, then snapshot, move into holding, delete the record and save,
    /// rolling back what was done when a step fails. Returns the workspace the session is held in
    /// when it worked.
    private func hold(
        _ session: HeldSession,
        context: ModelContext
    ) async -> (JobsViewModel.DeletionResult, Workspace?) {
        let sessionID = session.id
        // Off the list at once; nothing moves until every job of the session has stopped.
        removingSessionIDs.insert(sessionID)
        defer { removingSessionIDs.remove(sessionID) }
        await sessionJobs.cancelAndDrain(sessionID)

        guard let workspace = await workspaceService.currentWorkspace() else {
            logger.error("Refusing to delete a session with no workspace available.")
            return (.moveFailed, nil)
        }
        let isScoped = startAccess(workspace.rootURL)
        defer { if isScoped { stopAccess(workspace.rootURL) } }

        guard let folder = session.folder else {
            logger.error("Refusing to hold a session with no folder.")
            return (.moveFailed, nil)
        }
        guard JobsViewModel.isRemovableSessionFolder(folder, in: workspace) else {
            logger.error("Refusing to delete a session whose folder is outside the workspace: \(folder.path, privacy: .public)")
            return (.moveFailed, nil)
        }
        let holding = HoldingFolder(workspace: workspace)

        do {
            try session.snapshot(originalFolder: folder, deletedAt: now()).write(into: folder)
            try holding.hold(folder, sessionID: sessionID)
        } catch {
            logger.error("Could not hold session folder \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            removeSnapshot(from: folder)
            return (.moveFailed, nil)
        }

        session.delete(from: context)
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
        let folder = URL(fileURLWithPath: snapshot.originalFolderPath)

        // Before anything is inserted: seeding the default tag saves the context. Imported sessions
        // have no tags.
        var tags: [RecordingTag] = []
        if case .recording(let record) = snapshot.session {
            do {
                tags = try restorableTags(record.tagIDs, in: context)
            } catch {
                logger.error("Could not look up a restored session's tags: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }

        do {
            try holding.release(sessionID: sessionID, to: folder)
        } catch {
            logger.error("Could not move a held session back: \(error.localizedDescription, privacy: .public)")
            return false
        }

        switch snapshot.session {
        case .recording(let record):
            record.insertRecording(into: context).tags = tags
        case .imported(let record):
            _ = record.insertImported(into: context)
        }
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
                guard let session = try? HeldSession.fetch(id: sessionID, in: context) else {
                    undoManager.removeAllActions(withTarget: target)
                    self.logger.notice("Skipped redoing a delete: the session is not in the store.")
                    return
                }
                self.notifyRemoval(of: sessionID)
                let (result, workspace) = await self.hold(session, context: context)
                if result == .deleted, let workspace {
                    self.holds[sessionID] = Hold(workspace: workspace, target: target, undoManager: undoManager)
                    self.startExpiry(of: sessionID)
                    self.announce(Self.deletedAnnouncement)
                } else {
                    undoManager.removeAllActions(withTarget: target)
                    self.logger.error("Redoing a delete failed; the session stays restored.")
                }
            }
        }
        undoManager.setActionName(UndoActionName.deleteSession)
    }

    // MARK: - Pending deletions

    /// The snapshots of the sessions held in the active workspace, read from its holding folder, so
    /// they include sessions deleted in an earlier run.
    func heldSessions() async -> [SessionSnapshot] {
        guard let workspace = await workspaceService.currentWorkspace() else { return [] }
        let isScoped = startAccess(workspace.rootURL)
        defer { if isScoped { stopAccess(workspace.rootURL) } }
        return HoldingFolder(workspace: workspace).heldSnapshots()
    }

    /// Restores a held session of the active workspace and removes its undo entry from whichever
    /// window registered it. Works for a session deleted in an earlier run, which has no entry.
    /// Returns whether it worked.
    func restoreHeld(_ sessionID: UUID, context: ModelContext) async -> Bool {
        await enqueue(sessionID) { [self] in
            let registered = holds[sessionID]
            let target = registered?.target ?? DeletionUndoTarget(sessionID: sessionID)
            if registered == nil, let workspace = await workspaceService.currentWorkspace() {
                holds[sessionID] = Hold(workspace: workspace, target: target, undoManager: nil)
            }
            guard await restore(target, context: context) else {
                if registered == nil, holds[sessionID]?.target === target {
                    holds[sessionID] = nil
                }
                return false
            }
            registered?.undoManager?.removeAllActions(withTarget: target)
            announce(Self.restoredAnnouncement)
            return true
        }.value
    }

    /// Removes a held session of the active workspace for good and removes its undo entry from
    /// whichever window registered it.
    func removeHeld(_ sessionID: UUID) async -> RemovalResult {
        await enqueue(sessionID) { [self] in
            guard let workspace = await workspaceService.currentWorkspace() else {
                logger.notice("Skipped removing a held session with no workspace available.")
                return .notHeld
            }
            if let hold = holds.removeValue(forKey: sessionID) {
                hold.undoManager?.removeAllActions(withTarget: hold.target)
            }
            expiryTimers[sessionID] = nil
            let isScoped = startAccess(workspace.rootURL)
            defer { if isScoped { stopAccess(workspace.rootURL) } }
            let holding = HoldingFolder(workspace: workspace)
            do {
                try holding.remove(sessionID: sessionID)
                return .removed
            } catch {
                let folder = holding.heldFolder(for: sessionID)
                logger.error("Could not remove a held session folder \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .folderLeft(folder)
            }
        }.value
    }

    // MARK: - Expiry

    /// Schedules removing the session for good once it has been held for `holdDuration`. Called
    /// right after the session is held, so the snapshot's deletion time is `now()`.
    private func startExpiry(of sessionID: UUID) {
        scheduleExpiry(at: now().addingTimeInterval(Self.holdDuration), sessionID: sessionID)
    }

    /// The delay is measured on `now()`, so an injected clock and the timer agree.
    private func scheduleExpiry(at date: Date, sessionID: UUID) {
        expiryTimers[sessionID] = scheduleExpiry(date.timeIntervalSince(now())) { [weak self] in
            guard let self else { return }
            expiryTimers[sessionID] = nil
            enqueue(sessionID) { await self.expire(sessionID) }
        }
    }

    /// Removes the held session for good if its deletion time in the snapshot is `holdDuration`
    /// ago, and removes its undo entries. Failures are logged and leave the session held.
    private func expire(_ sessionID: UUID) async {
        guard let hold = holds[sessionID] else { return }
        guard await workspaceService.currentWorkspace() == hold.workspace else {
            logger.notice("Skipped removing a held session of a workspace that is not active.")
            return
        }
        let workspace = hold.workspace
        let isScoped = startAccess(workspace.rootURL)
        defer { if isScoped { stopAccess(workspace.rootURL) } }

        let holding = HoldingFolder(workspace: workspace)
        let folder = holding.heldFolder(for: sessionID)
        let deadline: Date
        do {
            deadline = try SessionSnapshot.read(from: folder).deletedAt.addingTimeInterval(Self.holdDuration)
        } catch {
            logger.error("Could not read the snapshot of an expiring held session; it stays held: \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        guard deadline <= now() else {
            scheduleExpiry(at: deadline, sessionID: sessionID)
            return
        }
        do {
            try holding.remove(sessionID: sessionID)
        } catch {
            logger.error("Could not remove an expired held session: \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        holds[sessionID] = nil
        hold.undoManager?.removeAllActions(withTarget: hold.target)
    }

    // MARK: - Workspace activation

    /// Whether a delete, restore or removal is queued or running, during which the workspace's
    /// security scope must stay available.
    var hasOperationInProgress: Bool {
        !operations.isEmpty
    }

    /// Makes `workspace` the one whose held sessions expire: stops every running expiry timer, runs
    /// the sweep, and starts a timer for each held session it leaves. Called at launch and after
    /// every workspace switch, so held sessions of another workspace wait until it is active again.
    func activate(_ workspace: Workspace, context: ModelContext) async {
        expiryTimers.removeAll()
        let isScoped = startAccess(workspace.rootURL)
        defer { if isScoped { stopAccess(workspace.rootURL) } }

        let result = HeldSessionSweep(
            workspace: workspace,
            context: context,
            now: now(),
            holdDuration: Self.holdDuration
        ).run()

        for sessionID in result.removed + result.notDeleted {
            if let hold = holds.removeValue(forKey: sessionID) {
                hold.undoManager?.removeAllActions(withTarget: hold.target)
            }
        }
        for snapshot in result.held {
            let sessionID = snapshot.sessionID
            // A session deleted in this run keeps its undo entry.
            if holds[sessionID]?.workspace != workspace {
                holds[sessionID] = Hold(
                    workspace: workspace,
                    target: DeletionUndoTarget(sessionID: sessionID),
                    undoManager: nil
                )
            }
            scheduleExpiry(at: snapshot.deletedAt.addingTimeInterval(Self.holdDuration), sessionID: sessionID)
        }
        holdingChanges.revision += 1
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
            self?.holdingChanges.revision += 1
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
