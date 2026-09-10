import Foundation
import SwiftData

@Model
final class RecordingSession {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    @Attribute(originalName: "audioURL") var micAudioURL: String
    var appAudioURL: String?
    var screenVideoURL: String?
    @Attribute var mixdownURL: String?
    var title: String
    var capturedAppName: String?
    var statusRawValue: String
    var errorMessage: String?
    var screenCaptureWarning: String?
    /// True when a recording was started with app audio but the app source produced no frames for
    /// its entire duration, so it was finalized as microphone-only. Stored as a flag rather than a
    /// message because the wording belongs to the view.
    var appAudioMissing: Bool?
    /// How many times capture was restarted mid-recording, or `nil` when it was never interrupted.
    ///
    /// A count rather than a flag: a recording interrupted once and one interrupted eleven times
    /// are materially different, and the count costs nothing to store. Stored as data, not a
    /// message — the wording belongs to the view, as with `appAudioMissing`.
    var captureInterruptionCount: Int?
    /// How many audio write failures the recording's capture recorded, or `nil` when there were
    /// none. The audio is intact; the failed intervals are silence of their real duration. Stored
    /// as data, not a message — the wording belongs to the view.
    var captureWriteFailureCount: Int?
    /// Sources that covered materially less of the recording than the recording ran, as source
    /// labels ("mic", "app"), or `nil` when every source covered it. The audio is real and
    /// correctly placed; the uncovered interval is silence. Stored as data, not a message.
    var partiallyCoveredSources: [String]?
    var mixdownAttemptCountValue: Int?
    var transcriptData: Data?
    var retranscriptData: Data?
    var aiTransformationsData: Data?
    /// Plain text this session can be searched by — the displayed transcript pass, kept current by
    /// the transcript setters. Optional and absent from the initialiser: existing sessions have it
    /// backfilled at startup rather than through a migration.
    var searchableText: String?
    var transcriptSegments: [RecordingTranscriptSegment] = []
    /// Tags carried by this recording — one to three, never zero.
    ///
    /// `RecordingTag.recordings` is the declared inverse. It is needed, not decorative: without it
    /// deleting a tag emptied this whole relationship instead of removing the one element.
    /// `TagService` still owns the bounds, which SwiftData cannot express either way.
    @Relationship var tags: [RecordingTag] = []
    var originalMixdownURL: String?
    var originalScreenVideoURL: String?
    var originalTranscriptData: Data?
    var originalRetranscriptData: Data?
    var trimEnd: Double?

    var isTrimmed: Bool { originalMixdownURL != nil }

    /// Whether this recording's capture was interrupted and restarted at least once, so it
    /// contains an interval of silence where capture was dead.
    var wasCaptureInterrupted: Bool { (captureInterruptionCount ?? 0) > 0 }

    /// Whether the recording's capture recorded one or more failed writes.
    var hadCaptureWriteFailures: Bool { (captureWriteFailureCount ?? 0) > 0 }

    /// Whether any captured source stopped producing audio partway through the recording.
    var hasPartiallyCoveredSource: Bool { !(partiallyCoveredSources ?? []).isEmpty }

    /// Whether part of this recording's audio is missing — a source that stopped partway, or writes
    /// that failed. Both leave an interval of silence, so the row reports them as one condition.
    var hasIncompleteCapturedAudio: Bool { hasPartiallyCoveredSource || hadCaptureWriteFailures }

    var status: RecordingStatus {
        get { RecordingStatus(persistedValue: statusRawValue, errorMessage: errorMessage) }
        set {
            statusRawValue = newValue.persistedValue
            switch newValue {
            case .error(let message):
                errorMessage = message
            default:
                errorMessage = nil
            }
        }
    }

    var mixdownAttemptCount: Int {
        get { mixdownAttemptCountValue ?? 0 }
        set { mixdownAttemptCountValue = newValue }
    }

    var transcript: Transcript? {
        get {
            guard let transcriptData else { return nil }
            return try? JSONDecoder().decode(Transcript.self, from: transcriptData)
        }
        set {
            if let newValue {
                transcriptData = try? JSONEncoder().encode(newValue)
            } else {
                transcriptData = nil
            }
            refreshSearchableText()
        }
    }

    var retranscript: Transcript? {
        get {
            guard let retranscriptData else { return nil }
            return try? JSONDecoder().decode(Transcript.self, from: retranscriptData)
        }
        set {
            if let newValue {
                retranscriptData = try? JSONEncoder().encode(newValue)
            } else {
                retranscriptData = nil
            }
            refreshSearchableText()
        }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        duration: TimeInterval,
        micAudioURL: String,
        appAudioURL: String? = nil,
        screenVideoURL: String? = nil,
        mixdownURL: String? = nil,
        title: String,
        capturedAppName: String? = nil,
        status: RecordingStatus = .recorded,
        errorMessage: String? = nil,
        mixdownAttemptCount: Int = 0,
        transcriptData: Data? = nil,
        retranscriptData: Data? = nil,
        aiTransformationsData: Data? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.micAudioURL = micAudioURL
        self.appAudioURL = appAudioURL
        self.screenVideoURL = screenVideoURL
        self.mixdownURL = mixdownURL
        self.title = title
        self.capturedAppName = capturedAppName
        self.statusRawValue = status.persistedValue
        self.errorMessage = errorMessage
        self.mixdownAttemptCountValue = mixdownAttemptCount
        self.transcriptData = transcriptData
        self.retranscriptData = retranscriptData
        self.aiTransformationsData = aiTransformationsData
        if case .error = status {
            self.status = status
        }
        refreshSearchableText()
    }
}

extension RecordingSession: TranscribableSession {}
