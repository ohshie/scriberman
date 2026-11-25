import Foundation
import Observation
import SwiftData

/// Throwing reads keep unknown membership distinct from an empty set. Both the saved store and
/// pending context changes count: an unsaved detach or delete must not retire original media.
@MainActor
struct SpliceMembershipReader {
    var liveGroupIDs: (ModelContext) throws -> Set<UUID> = { context in
        let saved = ModelContext(context.container)
        let persisted = try saved.fetch(FetchDescriptor<RecordingSession>()).compactMap(\.spliceGroupID)
        let pending = try context.fetch(FetchDescriptor<RecordingSession>()).compactMap(\.spliceGroupID)
        return Set(persisted + pending)
    }
    var heldGroupIDs: (Workspace) throws -> Set<UUID> = { workspace in
        Set(try HoldingFolder(workspace: workspace).snapshotsForMembership().compactMap(\.spliceGroupID))
    }
}

/// Every filesystem mutation of the transaction, including Markdown, uses this boundary.
struct SpliceFileOperations {
    /// Test seams model a stopped process rather than an ordinary operation failure. The store
    /// and filesystem are reopened before recovery; no filesystem rollback runs for this signal.
    struct Interruption: Error {}
    enum Checkpoint: Equatable {
        case storeSaved
        case memberProcessed(UUID)
    }
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
    var createDirectory: (URL, Bool) throws -> Void = {
        try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: $1)
    }
    var move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    var replace: (URL, URL) throws -> Void = {
        _ = try FileManager.default.replaceItemAt($0, withItemAt: $1)
    }
    var write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
}

struct SpliceManifest: Codable, Equatable {
    static let fileName = "manifest.json"
    var formatVersion = 1
    let originalSessionID: UUID
    let title: String
    let createdAt: Date
    let duration: Double
    var transcriptData: Data?
    var retranscriptData: Data?
    let hasScreenVideo: Bool

    init(session: RecordingSession) {
        originalSessionID = session.id
        title = session.title
        createdAt = session.createdAt
        duration = session.duration
        transcriptData = session.transcriptData
        retranscriptData = session.retranscriptData
        hasScreenVideo = session.screenVideoURL != nil
    }

    init(originalSessionID: UUID, title: String, createdAt: Date, duration: Double,
         transcriptData: Data?, retranscriptData: Data?, hasScreenVideo: Bool) {
        self.originalSessionID = originalSessionID
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.transcriptData = transcriptData
        self.retranscriptData = retranscriptData
        self.hasScreenVideo = hasScreenVideo
    }
}

/// Written in full before the first move. Backups and staged exports have distinct paths, so
/// recovery can reverse completed moves by examining which destinations exist.
struct SpliceJournal: Codable {
    static let fileName = "journal.json"
    struct Move: Codable {
        let source: URL
        let destination: URL
    }
    struct Result: Codable {
        let sessionID: UUID
        let createdAt: Date
        let duration: Double
        let title: String
        let transcriptData: Data?
        let retranscriptData: Data?
    }
    var formatVersion = 1
    var operation = "splice"
    let groupID: UUID
    let createsGroup: Bool
    let originalRecord: RecordingSessionRecord
    let moves: [Move]
    let newFolders: [URL]
    let stagingFolder: URL
    let markdownURL: URL
    let previousMarkdown: Data?
    let results: [Result]
    let startedAt: Date
    var restoreMemberIDs: [UUID]? = nil
    /// Written before retiring any rollback backups, so cleanup can be retried independently.
    var rollbackCompleted: Bool? = nil
}

/// Reconciliation's caller has already authorized this workspace. The app supplies its long-lived
/// coordinator; standalone service callers still use the same deletion implementation.
struct ReconciliationWorkspace: WorkspaceServiceProtocol {
    let workspace: Workspace
    func currentWorkspace() async -> Workspace? { workspace }
    func requireAuthorizedWorkspace() async throws(WorkspaceError) -> Workspace { workspace }
}

/// Shared exclusion for splice, restore and session mutations across service instances.
@MainActor
@Observable
final class SpliceReservations {
    static let shared = SpliceReservations()
    /// Restore may hold its own reserved members. Only an active lease grants that permission.
    struct Reservation: Equatable {
        fileprivate let id = UUID()
        let sessionIDs: Set<UUID>
        let groupID: UUID
    }
    private var active: [UUID: Reservation] = [:]

    var hasReservations: Bool { !active.isEmpty }

    func isReserved(_ session: any TranscribableSession) -> Bool {
        isReserved(sessionID: session.id, groupID: (session as? RecordingSession)?.spliceGroupID)
    }

    func isReserved(sessionID: UUID, groupID: UUID? = nil) -> Bool {
        active.values.contains { $0.sessionIDs.contains(sessionID) || $0.groupID == groupID }
    }

    func reserve(sessionID: UUID, groupID: UUID) throws {
        _ = try reserve(sessionIDs: [sessionID], groupID: groupID)
    }

    func reserve(sessionIDs: Set<UUID>, groupID: UUID) throws -> Reservation {
        guard !active.values.contains(where: { $0.groupID == groupID || !$0.sessionIDs.isDisjoint(with: sessionIDs) }) else {
            throw SpliceError.busy
        }
        let reservation = Reservation(sessionIDs: sessionIDs, groupID: groupID)
        active[reservation.id] = reservation
        return reservation
    }

    func permits(_ reservation: Reservation?, sessionID: UUID) -> Bool {
        guard let reservation, active[reservation.id] == reservation else { return false }
        return reservation.sessionIDs.contains(sessionID)
    }

    func release(sessionID: UUID, groupID: UUID) {
        guard let reservation = active.values.first(where: { $0.groupID == groupID && $0.sessionIDs == [sessionID] }) else { return }
        release(reservation)
    }

    func release(_ reservation: Reservation) { active[reservation.id] = nil }
}
