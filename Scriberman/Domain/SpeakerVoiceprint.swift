import Foundation
import SwiftData

/// The transcript, of a session's two, that a voiceprint was taught from.
enum TranscriptPass: String, Codable, Sendable {
    case transcript
    case retranscript
}

/// Where a voiceprint came from: a speaker of one pass of one session. Speaker IDs repeat across
/// passes, so the pass is part of the key.
struct VoiceprintSource: Hashable, Sendable {
    let sessionID: UUID
    let pass: TranscriptPass
    let speakerID: String
}

/// One voiceprint a speaker profile was taught.
@Model
final class SpeakerVoiceprint {
    @Attribute(.unique) var id: UUID
    var embedding: [Float]
    /// How many voiceprints this one stands for. A voiceprint migrated from a profile's running
    /// mean has that profile's sample count; every other one has 1.
    var weight: Int
    var sourceSessionID: UUID?
    /// A `TranscriptPass` raw value.
    var sourcePass: String?
    var sourceSpeakerID: String?
    var createdAt: Date
    var profile: SpeakerProfile?

    init(
        id: UUID = UUID(),
        embedding: [Float],
        weight: Int = 1,
        source: VoiceprintSource? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.embedding = embedding
        self.weight = weight
        self.sourceSessionID = source?.sessionID
        self.sourcePass = source?.pass.rawValue
        self.sourceSpeakerID = source?.speakerID
        self.createdAt = createdAt
    }

    /// The source, or `nil` for a voiceprint migrated from before sources existed.
    var source: VoiceprintSource? {
        guard let sourceSessionID,
              let pass = sourcePass.flatMap(TranscriptPass.init(rawValue:)),
              let sourceSpeakerID
        else { return nil }
        return VoiceprintSource(sessionID: sourceSessionID, pass: pass, speakerID: sourceSpeakerID)
    }
}

struct SpeakerVoiceprintSnapshot: Sendable, Identifiable {
    let id: UUID
    let weight: Int
    let source: VoiceprintSource?
    let createdAt: Date

    init(voiceprint: SpeakerVoiceprint) {
        self.id = voiceprint.id
        self.weight = voiceprint.weight
        self.source = voiceprint.source
        self.createdAt = voiceprint.createdAt
    }
}
