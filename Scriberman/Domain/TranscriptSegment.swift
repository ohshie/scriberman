import Foundation

enum AudioSource: String, Codable, Equatable {
    case mic
    case app
}

struct TranscriptSegment: Codable, Equatable {
    /// Stable identity used for retroactive speaker corrections during live transcription.
    /// Omitted from legacy encoded payloads — decoded with a fallback UUID when absent.
    let id: UUID
    let speakerId: String
    let text: String
    let startTime: Float
    let endTime: Float
    let audioSource: AudioSource
    let isFinal: Bool

    init(
        id: UUID = UUID(),
        speakerId: String,
        text: String,
        startTime: Float,
        endTime: Float,
        audioSource: AudioSource = .mic,
        isFinal: Bool = true
    ) {
        self.id = id
        self.speakerId = speakerId
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.audioSource = audioSource
        self.isFinal = isFinal
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case speakerId
        case text
        case startTime
        case endTime
        case audioSource
        case isFinal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        speakerId = try container.decode(String.self, forKey: .speakerId)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(Float.self, forKey: .startTime)
        endTime = try container.decode(Float.self, forKey: .endTime)
        audioSource = try container.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? .mic
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(speakerId, forKey: .speakerId)
        try container.encode(text, forKey: .text)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(audioSource, forKey: .audioSource)
        try container.encode(isFinal, forKey: .isFinal)
    }
}

struct TranscriptBlock: Identifiable {
    let id = UUID()
    let speaker: TranscriptSpeaker
    let audioSource: AudioSource
    let startTime: Float
    let endTime: Float
    let text: String
}
