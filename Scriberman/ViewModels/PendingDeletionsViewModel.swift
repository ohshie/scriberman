import Foundation
import Observation
import SwiftData

/// The Pending deletions view of one window: the active workspace's held sessions, newest delete
/// first, and whether the view is open.
///
/// The holding folder is the source of truth, so the rows include sessions deleted in an earlier
/// run. There is no empty state: the entry point is inactive with nothing held, and the view
/// closes when the last row goes.
@MainActor
@Observable
final class PendingDeletionsViewModel {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let title: String
        let createdAt: Date
        let duration: TimeInterval
        let deletedAt: Date
    }

    /// How long a deleted session can be restored.
    static let restorePeriod: TimeInterval = 24 * 60 * 60

    private(set) var rows: [Row] = []
    private(set) var isOpen = false

    @ObservationIgnored private let coordinator: SessionDeletionCoordinator
    @ObservationIgnored private let now: @MainActor () -> Date

    init(coordinator: SessionDeletionCoordinator, now: @escaping @MainActor () -> Date = { .now }) {
        self.coordinator = coordinator
        self.now = now
    }

    var isEntryEnabled: Bool {
        !rows.isEmpty
    }

    /// Reads the holding folder again. Closes the view when nothing is held any more.
    func refresh() async {
        rows = await coordinator.heldSessions()
            .map { snapshot in
                Row(
                    id: snapshot.sessionID,
                    title: snapshot.title,
                    createdAt: snapshot.createdAt,
                    duration: snapshot.duration,
                    deletedAt: snapshot.deletedAt
                )
            }
            .sorted { $0.deletedAt > $1.deletedAt }
        if rows.isEmpty {
            isOpen = false
        }
    }

    func open() {
        guard isEntryEnabled else { return }
        isOpen = true
    }

    func close() {
        isOpen = false
    }

    /// The time until `row` is removed, rounded down.
    func countdownText(for row: Row) -> String {
        let remaining = row.deletedAt.addingTimeInterval(Self.restorePeriod).timeIntervalSince(now())
        if remaining >= 3_600 {
            return "Removed in \(Int(remaining / 3_600)) h"
        }
        if remaining >= 60 {
            return "Removed in \(Int(remaining / 60)) min"
        }
        return "Removed in under 1 min"
    }

    /// Restores the session and closes the view, since the restored session is selected. Returns
    /// the session's `id` to select, or `nil` when the restore failed.
    func revert(_ row: Row, context: ModelContext) async -> UUID? {
        let restored = await coordinator.restoreHeld(row.id, context: context)
        await refresh()
        guard restored else { return nil }
        close()
        return row.id
    }

    /// Removes the session for good. The caller asks for confirmation first.
    func removeNow(_ row: Row) async -> SessionDeletionCoordinator.RemovalResult {
        let result = await coordinator.removeHeld(row.id)
        await refresh()
        return result
    }
}
