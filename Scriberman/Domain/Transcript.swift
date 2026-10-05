import Foundation

struct Transcript: Codable, Equatable {
    var fullText: String
    var segments: [TranscriptSegment]
    var speakers: [TranscriptSpeaker]
    var speakerEmbeddings: [String: [Float]]?
    /// Speaker ID → the profile a live session auto-enrolled for that speaker. A link means
    /// this transcript owns the profile, so renaming the speaker may rename the profile.
    var speakerProfileIDs: [String: UUID]?
    /// The voiceprint space of `speakerEmbeddings`. `nil` for transcripts saved before voiceprint
    /// spaces existed; their voiceprints never reach speaker memory.
    var voiceprintSpace: String?

    init(
        fullText: String,
        segments: [TranscriptSegment],
        speakers: [TranscriptSpeaker],
        speakerEmbeddings: [String: [Float]]? = nil,
        speakerProfileIDs: [String: UUID]? = nil,
        voiceprintSpace: String? = nil
    ) {
        self.fullText = fullText
        self.segments = segments
        self.speakers = speakers
        self.speakerEmbeddings = speakerEmbeddings
        self.speakerProfileIDs = speakerProfileIDs
        self.voiceprintSpace = voiceprintSpace
    }

    /// The full text of a transcript made of `segments`. Transcription and trim both build
    /// `fullText` here, so a trimmed transcript's text cannot drift from a transcribed one's.
    static func fullText(joining segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }
}
