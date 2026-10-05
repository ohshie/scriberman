import Foundation

struct Transcript: Codable, Equatable {
    var fullText: String
    var segments: [TranscriptSegment]
    var speakers: [TranscriptSpeaker]
    /// Speaker ID → that speaker's voiceprints. A list holds one voiceprint per speaker ID the
    /// speaker was made of; it grows only when another speaker is merged into it.
    var speakerVoiceprints: [String: [[Float]]]?
    /// Speaker ID → the profile a live session auto-enrolled for that speaker. A link means
    /// this transcript owns the profile, so renaming the speaker may rename the profile.
    var speakerProfileIDs: [String: UUID]?
    /// The voiceprint space of `speakerVoiceprints`. `nil` for transcripts saved before voiceprint
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
        self.speakerVoiceprints = speakerEmbeddings?.mapValues { [$0] }
        self.speakerProfileIDs = speakerProfileIDs
        self.voiceprintSpace = voiceprintSpace
    }

    /// One voiceprint per speaker: the mean of each speaker's list. Setting it gives each speaker a
    /// list of one. Written alongside `speakerVoiceprints`, so an older build still reads one
    /// voiceprint per speaker.
    var speakerEmbeddings: [String: [Float]]? {
        get { speakerVoiceprints?.compactMapValues(Self.mean(of:)) }
        set { speakerVoiceprints = newValue?.mapValues { [$0] } }
    }

    /// The element-wise mean of `voiceprints`, or `nil` when there are none.
    static func mean(of voiceprints: [[Float]]) -> [Float]? {
        guard let first = voiceprints.first else { return nil }
        guard voiceprints.count > 1 else { return first }
        var sum = [Float](repeating: 0, count: first.count)
        for voiceprint in voiceprints where voiceprint.count == first.count {
            for index in sum.indices {
                sum[index] += voiceprint[index]
            }
        }
        let count = Float(voiceprints.filter { $0.count == first.count }.count)
        return sum.map { $0 / count }
    }

    /// The full text of a transcript made of `segments`. Transcription and trim both build
    /// `fullText` here, so a trimmed transcript's text cannot drift from a transcribed one's.
    static func fullText(joining segments: [TranscriptSegment]) -> String {
        segments.map(\.text).joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case fullText, segments, speakers, speakerVoiceprints, speakerEmbeddings, speakerProfileIDs, voiceprintSpace
    }

    /// Reads `speakerVoiceprints`, or, for a transcript saved before voiceprint lists existed,
    /// `speakerEmbeddings` as lists of one.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fullText = try container.decode(String.self, forKey: .fullText)
        segments = try container.decode([TranscriptSegment].self, forKey: .segments)
        speakers = try container.decode([TranscriptSpeaker].self, forKey: .speakers)
        if let lists = try container.decodeIfPresent([String: [[Float]]].self, forKey: .speakerVoiceprints) {
            speakerVoiceprints = lists
        } else {
            speakerVoiceprints = try container.decodeIfPresent([String: [Float]].self, forKey: .speakerEmbeddings)?
                .mapValues { [$0] }
        }
        speakerProfileIDs = try container.decodeIfPresent([String: UUID].self, forKey: .speakerProfileIDs)
        voiceprintSpace = try container.decodeIfPresent(String.self, forKey: .voiceprintSpace)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fullText, forKey: .fullText)
        try container.encode(segments, forKey: .segments)
        try container.encode(speakers, forKey: .speakers)
        try container.encodeIfPresent(speakerVoiceprints, forKey: .speakerVoiceprints)
        try container.encodeIfPresent(speakerEmbeddings, forKey: .speakerEmbeddings)
        try container.encodeIfPresent(speakerProfileIDs, forKey: .speakerProfileIDs)
        try container.encodeIfPresent(voiceprintSpace, forKey: .voiceprintSpace)
    }
}
