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
