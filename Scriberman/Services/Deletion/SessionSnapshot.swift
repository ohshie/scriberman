import Foundation
import SwiftData

/// A deleted session's record, written into its folder so the folder can bring the record back.
///
/// The snapshot file is also the marker of a delete or restore in progress: it is written before
/// the folder moves into holding, and removed only once a delete has been rolled back or a restore
/// has saved. Its presence is how an interrupted operation is recognised later.
///
/// Stored values are kept raw, as the store holds them, so a restore writes back exactly what was
/// there. `RecordingTranscriptSegment` is copied field by field rather than through the Codable
/// `TranscriptSegment`, which has no `createdAt` and stores the interpreted `AudioSource`.
struct SessionSnapshot: Codable, Equatable {
    /// Hidden, so a snapshot left in a session folder by an interrupted operation stays out of the
    /// way in Finder.
    static let fileName = ".deletion-snapshot.json"

    enum Session: Codable, Equatable {
        case recording(RecordingSessionRecord)
        case imported(ImportedSessionRecord)
    }

    let session: Session
    let originalFolderPath: String
    let deletedAt: Date

    init(recording: RecordingSession, originalFolder: URL, deletedAt: Date) {
        session = .recording(RecordingSessionRecord(recording))
        originalFolderPath = originalFolder.path
        self.deletedAt = deletedAt
    }

    init(imported: ImportedSession, originalFolder: URL, deletedAt: Date) {
        session = .imported(ImportedSessionRecord(imported))
        originalFolderPath = originalFolder.path
        self.deletedAt = deletedAt
    }

    var sessionID: UUID {
        switch session {
        case .recording(let record): record.id
        case .imported(let record): record.id
        }
    }

    var title: String {
        switch session {
        case .recording(let record): record.title
        case .imported(let record): record.title
        }
    }

    var createdAt: Date {
        switch session {
        case .recording(let record): record.createdAt
        case .imported(let record): record.createdAt
        }
    }

    var duration: TimeInterval {
        switch session {
        case .recording(let record): record.duration
        case .imported(let record): record.duration
        }
    }

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(fileName, isDirectory: false)
    }

    static func exists(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: folder).path)
    }

    static func read(from folder: URL) throws -> SessionSnapshot {
        try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: url(in: folder)))
    }

    /// Writes the snapshot into `folder`, creating the folder when it is gone, so a session whose
    /// files were removed outside the app can still be deleted and restored.
    func write(into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(in: folder), options: .atomic)
    }

    static func remove(from folder: URL) throws {
        do {
            try FileManager.default.removeItem(at: url(in: folder))
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        }
    }
}

/// Every stored property of a `RecordingSession`, its tag IDs and its transcript segments.
struct RecordingSessionRecord: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let micAudioURL: String
    let appAudioURL: String?
    let screenVideoURL: String?
    let mixdownURL: String?
    let title: String
    let capturedAppName: String?
    let statusRawValue: String
    let errorMessage: String?
    let screenCaptureWarning: String?
    let appAudioMissing: Bool?
    let captureInterruptionCount: Int?
    let captureWriteFailureCount: Int?
    let partiallyCoveredSources: [String]?
    let mixdownAttemptCountValue: Int?
    let screenMuxState: String?
    let videoStartHostTimeNanos: Int64?
    let audioAnchorHostTimeNanos: Int64?
    let screenMuxAttemptCountValue: Int?
    let audioSyncTimelineMixdownEnabled: Bool?
    let audioSyncUnifiedCaptureEnabled: Bool?
    let audioSyncCaptureHealthRecoveryEnabled: Bool?
    let transcriptData: Data?
    let retranscriptData: Data?
    let aiTransformationsData: Data?
    let searchableText: String?
    let originalMixdownURL: String?
    let originalScreenVideoURL: String?
    let originalTranscriptData: Data?
    let originalRetranscriptData: Data?
    let trimEnd: Double?
    let tagIDs: [UUID]
    let transcriptSegments: [SegmentRecord]

    /// Every stored property of a `RecordingTranscriptSegment`.
    struct SegmentRecord: Codable, Equatable {
        let id: UUID
        let createdAt: Date
        let speakerId: String
        let text: String
        let startTime: Float
        let endTime: Float
        let audioSourceRawValue: String
        let isFinal: Bool
    }

    init(_ session: RecordingSession) {
        id = session.id
        createdAt = session.createdAt
        duration = session.duration
        micAudioURL = session.micAudioURL
        appAudioURL = session.appAudioURL
        screenVideoURL = session.screenVideoURL
        mixdownURL = session.mixdownURL
        title = session.title
        capturedAppName = session.capturedAppName
        statusRawValue = Self.heldStatusRawValue(of: session)
        errorMessage = session.errorMessage
        screenCaptureWarning = session.screenCaptureWarning
        appAudioMissing = session.appAudioMissing
        captureInterruptionCount = session.captureInterruptionCount
        captureWriteFailureCount = session.captureWriteFailureCount
        partiallyCoveredSources = session.partiallyCoveredSources
        mixdownAttemptCountValue = session.mixdownAttemptCountValue
        screenMuxState = session.screenMuxState
        videoStartHostTimeNanos = session.videoStartHostTimeNanos
        audioAnchorHostTimeNanos = session.audioAnchorHostTimeNanos
        screenMuxAttemptCountValue = session.screenMuxAttemptCountValue
        audioSyncTimelineMixdownEnabled = session.audioSyncTimelineMixdownEnabled
        audioSyncUnifiedCaptureEnabled = session.audioSyncUnifiedCaptureEnabled
        audioSyncCaptureHealthRecoveryEnabled = session.audioSyncCaptureHealthRecoveryEnabled
        transcriptData = session.transcriptData
        retranscriptData = session.retranscriptData
        aiTransformationsData = session.aiTransformationsData
        searchableText = session.searchableText
        originalMixdownURL = session.originalMixdownURL
        originalScreenVideoURL = session.originalScreenVideoURL
        originalTranscriptData = session.originalTranscriptData
        originalRetranscriptData = session.originalRetranscriptData
        trimEnd = session.trimEnd
        tagIDs = session.tags.map(\.id)
        transcriptSegments = session.transcriptSegments.map { segment in
            SegmentRecord(
                id: segment.id,
                createdAt: segment.createdAt,
                speakerId: segment.speakerId,
                text: segment.text,
                startTime: segment.startTime,
                endTime: segment.endTime,
                audioSourceRawValue: segment.audioSourceRawValue,
                isFinal: segment.isFinal
            )
        }
    }

    /// The status a held recording is stored with: one the user can act on once it is restored,
    /// since a delete stops whatever job the status names. This is the one stored value that does
    /// not round-trip exactly.
    private static func heldStatusRawValue(of session: RecordingSession) -> String {
        switch session.status {
        case .converting where FileManager.default.fileExists(atPath: session.micAudioURL):
            RecordingStatus.recorded.persistedValue
        case .transcribing:
            RecordingStatus.recorded.persistedValue
        case .retranscribing where session.transcriptData != nil || session.retranscriptData != nil:
            RecordingStatus.done.persistedValue
        case .retranscribing:
            RecordingStatus.recorded.persistedValue
        default:
            session.statusRawValue
        }
    }

    /// Inserts a recording carrying every stored value of this record, with its segments, into
    /// `context`, and returns it. Tags are left to the caller, which knows which still exist.
    func insertRecording(into context: ModelContext) -> RecordingSession {
        let session = RecordingSession(duration: duration, micAudioURL: micAudioURL, title: title)
        session.id = id
        session.createdAt = createdAt
        session.appAudioURL = appAudioURL
        session.screenVideoURL = screenVideoURL
        session.mixdownURL = mixdownURL
        session.capturedAppName = capturedAppName
        session.statusRawValue = statusRawValue
        session.errorMessage = errorMessage
        session.screenCaptureWarning = screenCaptureWarning
        session.appAudioMissing = appAudioMissing
        session.captureInterruptionCount = captureInterruptionCount
        session.captureWriteFailureCount = captureWriteFailureCount
        session.partiallyCoveredSources = partiallyCoveredSources
        session.mixdownAttemptCountValue = mixdownAttemptCountValue
        session.screenMuxState = screenMuxState
        session.videoStartHostTimeNanos = videoStartHostTimeNanos
        session.audioAnchorHostTimeNanos = audioAnchorHostTimeNanos
        session.screenMuxAttemptCountValue = screenMuxAttemptCountValue
        session.audioSyncTimelineMixdownEnabled = audioSyncTimelineMixdownEnabled
        session.audioSyncUnifiedCaptureEnabled = audioSyncUnifiedCaptureEnabled
        session.audioSyncCaptureHealthRecoveryEnabled = audioSyncCaptureHealthRecoveryEnabled
        // The raw fields, not the `transcript` setters, which would recompute `searchableText`.
        session.transcriptData = transcriptData
        session.retranscriptData = retranscriptData
        session.aiTransformationsData = aiTransformationsData
        session.searchableText = searchableText
        session.originalMixdownURL = originalMixdownURL
        session.originalScreenVideoURL = originalScreenVideoURL
        session.originalTranscriptData = originalTranscriptData
        session.originalRetranscriptData = originalRetranscriptData
        session.trimEnd = trimEnd
        context.insert(session)
        session.transcriptSegments = transcriptSegments.map { record in
            let segment = RecordingTranscriptSegment(
                id: record.id,
                createdAt: record.createdAt,
                speakerId: record.speakerId,
                text: record.text,
                startTime: record.startTime,
                endTime: record.endTime,
                audioSource: .mic,
                isFinal: record.isFinal
            )
            segment.audioSourceRawValue = record.audioSourceRawValue
            return segment
        }
        return session
    }
}

/// Every stored property of an `ImportedSession`. Imported sessions have no tags and no transcript
/// segments.
struct ImportedSessionRecord: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let duration: TimeInterval
    let mixdownURL: String?
    let title: String
    let originalFileName: String
    let originalFormat: String
    let statusRawValue: String
    let errorMessage: String?
    let transcriptData: Data?
    let retranscriptData: Data?
    let aiTransformationsData: Data?
    let searchableText: String?

    init(_ session: ImportedSession) {
        id = session.id
        createdAt = session.createdAt
        duration = session.duration
        mixdownURL = session.mixdownURL
        title = session.title
        originalFileName = session.originalFileName
        originalFormat = session.originalFormat
        statusRawValue = session.statusRawValue
        errorMessage = session.errorMessage
        transcriptData = session.transcriptData
        retranscriptData = session.retranscriptData
        aiTransformationsData = session.aiTransformationsData
        searchableText = session.searchableText
    }

    /// Inserts an imported session carrying every stored value of this record into `context`, and
    /// returns it.
    func insertImported(into context: ModelContext) -> ImportedSession {
        let session = ImportedSession(
            id: id,
            createdAt: createdAt,
            duration: duration,
            mixdownURL: mixdownURL,
            title: title,
            originalFileName: originalFileName,
            originalFormat: originalFormat
        )
        // The raw fields, not `status` or the `transcript` setters, which would rewrite
        // `errorMessage` and recompute `searchableText`.
        session.statusRawValue = statusRawValue
        session.errorMessage = errorMessage
        session.transcriptData = transcriptData
        session.retranscriptData = retranscriptData
        session.aiTransformationsData = aiTransformationsData
        session.searchableText = searchableText
        context.insert(session)
        return session
    }
}
