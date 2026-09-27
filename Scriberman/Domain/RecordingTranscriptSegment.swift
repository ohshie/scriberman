import Foundation
import SwiftData

@Model
final class RecordingTranscriptSegment {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var speakerId: String
    var text: String
    var startTime: Float
    var endTime: Float
    var audioSourceRawValue: String
    var isFinal: Bool

    var session: RecordingSession?

    var audioSource: AudioSource {
        get { AudioSource(rawValue: audioSourceRawValue) ?? .mic }
        set { audioSourceRawValue = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        speakerId: String,
        text: String,
        startTime: Float,
        endTime: Float,
        audioSource: AudioSource,
        isFinal: Bool = true,
        session: RecordingSession? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.speakerId = speakerId
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.audioSourceRawValue = audioSource.rawValue
        self.isFinal = isFinal
        self.session = session
    }

    convenience init(
        segment: TranscriptSegment,
        createdAt: Date = .now,
        session: RecordingSession? = nil
    ) {
        self.init(
            id: segment.id,
            createdAt: createdAt,
            speakerId: segment.speakerId,
            text: segment.text,
            startTime: segment.startTime,
            endTime: segment.endTime,
            audioSource: segment.audioSource,
            isFinal: segment.isFinal,
            session: session
        )
    }
}

extension RecordingTranscriptSegment {
    /// Deletes segments that belong to no recording and returns how many went.
    ///
    /// Before `RecordingSession.transcriptSegments` cascaded, deleting a recording left its
    /// segments behind with a nil session. Idempotent: with no orphans it fetches and returns 0.
    @discardableResult
    static func deleteOrphans(in context: ModelContext) throws -> Int {
        let orphans = try context.fetch(FetchDescriptor<RecordingTranscriptSegment>(
            predicate: #Predicate { $0.session == nil }
        ))
        guard !orphans.isEmpty else { return 0 }
        for orphan in orphans {
            context.delete(orphan)
        }
        try context.save()
        return orphans.count
    }
}
