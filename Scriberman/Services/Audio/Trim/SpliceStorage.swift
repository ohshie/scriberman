import Foundation

/// Every filesystem mutation of the transaction, including Markdown, uses this boundary.
struct SpliceFileOperations {
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
    let transcriptData: Data?
    let retranscriptData: Data?
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
}

/// Prevents concurrent splices of a session or group across service instances.
@MainActor
final class SpliceReservations {
    static let shared = SpliceReservations()
    private var sessions: Set<UUID> = []
    private var groups: Set<UUID> = []

    func isReserved(sessionID: UUID, groupID: UUID) -> Bool {
        sessions.contains(sessionID) || groups.contains(groupID)
    }

    func reserve(sessionID: UUID, groupID: UUID) throws {
        guard !isReserved(sessionID: sessionID, groupID: groupID) else { throw SpliceError.busy }
        sessions.insert(sessionID)
        groups.insert(groupID)
    }

    func release(sessionID: UUID, groupID: UUID) {
        sessions.remove(sessionID)
        groups.remove(groupID)
    }
}
