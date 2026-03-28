import Foundation

enum AudioSource: String, Codable, Equatable {
    case mic
    case app
}

struct TranscriptSegment: Codable, Equatable {
    let speakerId: String
    let text: String
    let startTime: Float
    let endTime: Float
    let audioSource: AudioSource

    init(
        speakerId: String,
        text: String,
        startTime: Float,
        endTime: Float,
        audioSource: AudioSource = .mic
    ) {
        self.speakerId = speakerId
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.audioSource = audioSource
    }

    private enum CodingKeys: String, CodingKey {
        case speakerId
        case text
        case startTime
        case endTime
        case audioSource
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speakerId = try container.decode(String.self, forKey: .speakerId)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(Float.self, forKey: .startTime)
        endTime = try container.decode(Float.self, forKey: .endTime)
        audioSource = try container.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? .mic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speakerId, forKey: .speakerId)
        try container.encode(text, forKey: .text)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(audioSource, forKey: .audioSource)
    }
}
