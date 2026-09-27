import CryptoKit
import Foundation

enum AudioSource: String, Codable, Equatable, CaseIterable {
    case mic
    case app
}

struct TranscriptSegment: Codable, Equatable {
    /// Stable identity used for retroactive speaker corrections during live transcription.
    /// Legacy payloads receive a deterministic ID derived from their content.
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
        speakerId = try container.decode(String.self, forKey: .speakerId)
        text = try container.decode(String.self, forKey: .text)
        startTime = try container.decode(Float.self, forKey: .startTime)
        endTime = try container.decode(Float.self, forKey: .endTime)
        audioSource = try container.decodeIfPresent(AudioSource.self, forKey: .audioSource) ?? .mic
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal) ?? true
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? Self.legacyID(
            startTime: startTime, endTime: endTime, speakerId: speakerId,
            audioSource: audioSource, text: text
        )
    }

    private static func legacyID(
        startTime: Float, endTime: Float, speakerId: String,
        audioSource: AudioSource, text: String
    ) -> UUID {
        // Fixed-width timestamps and length-prefixed UTF-8 keep field boundaries unambiguous.
        var content = Data()
        for time in [startTime, endTime] {
            var bits = time.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { content.append(contentsOf: $0) }
        }
        for value in [speakerId, audioSource.rawValue, text] {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { content.append(contentsOf: $0) }
            content.append(bytes)
        }
        var bytes = Array(SHA256.hash(data: content).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // Version 8: custom content-derived UUID.
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC variant.
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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
    let id: UUID
    let speaker: TranscriptSpeaker
    let audioSource: AudioSource
    let startTime: Float
    let endTime: Float
    let text: String

    init(
        id: UUID = UUID(),
        speaker: TranscriptSpeaker,
        audioSource: AudioSource,
        startTime: Float,
        endTime: Float,
        text: String
    ) {
        self.id = id
        self.speaker = speaker
        self.audioSource = audioSource
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
