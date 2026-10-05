import Foundation
import SwiftData

/// The speaker-embedding model every stored voiceprint comes from. Voiceprints from different
/// spaces are never compared.
enum VoiceprintSpace {
    static let current = "wespeaker_v2"
}

@Model
final class SpeakerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    /// The weighted mean of `voiceprints`, kept as a cache so matching never faults the
    /// voiceprints and an older build that ignores them still matches correctly.
    var embedding: [Float]
    var lastSeen: Date
    /// The voiceprint space `embedding` belongs to. Rows stored before spaces existed read `""`.
    var voiceprintSpace: String = ""
    /// The sum of the voiceprints' weights, kept as a cache with `embedding`.
    var sampleCount: Int = 1
    @Relationship(deleteRule: .cascade, inverse: \SpeakerVoiceprint.profile)
    var voiceprints: [SpeakerVoiceprint] = []

    init(
        id: UUID = UUID(),
        name: String,
        embedding: [Float],
        lastSeen: Date = .now,
        voiceprintSpace: String = VoiceprintSpace.current,
        sampleCount: Int = 1
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.lastSeen = lastSeen
        self.voiceprintSpace = voiceprintSpace
        self.sampleCount = sampleCount
    }
}

extension SpeakerProfile {
    /// UserDefaults key holding the voiceprint space speaker memory was last reset for.
    static let voiceprintSpaceMarkerKey = "speakerMemory.voiceprintSpace"

    /// Deletes every profile when the recorded voiceprint space differs from the current one (or
    /// none is recorded), then records the current space. The marker is written only after the
    /// deletion is saved, so a failed reset is retried at the next launch.
    /// - Returns: the number of profiles deleted.
    @discardableResult
    static func resetIfVoiceprintSpaceChanged(in context: ModelContext, userDefaults: UserDefaults) throws -> Int {
        guard userDefaults.string(forKey: voiceprintSpaceMarkerKey) != VoiceprintSpace.current else { return 0 }
        let profiles = try context.fetch(FetchDescriptor<SpeakerProfile>())
        for profile in profiles {
            context.delete(profile)
        }
        try context.save()
        userDefaults.set(VoiceprintSpace.current, forKey: voiceprintSpaceMarkerKey)
        return profiles.count
    }

    /// Gives each profile that has no voiceprints one source-less voiceprint: its stored mean,
    /// weighted by its sample count. The cached mean and count do not change, so matching does
    /// not either. Idempotent, so it needs no marker.
    /// - Returns: the number of profiles migrated.
    @discardableResult
    static func migrateToVoiceprintLists(in context: ModelContext) throws -> Int {
        let profiles = try context.fetch(FetchDescriptor<SpeakerProfile>()).filter { $0.voiceprints.isEmpty }
        for profile in profiles {
            let voiceprint = SpeakerVoiceprint(embedding: profile.embedding, weight: max(profile.sampleCount, 1))
            context.insert(voiceprint)
            profile.voiceprints.append(voiceprint)
        }
        if !profiles.isEmpty {
            try context.save()
        }
        return profiles.count
    }

    static func fetch(id: UUID, in context: ModelContext) throws -> SpeakerProfile? {
        let targetID = id
        var descriptor = FetchDescriptor<SpeakerProfile>(predicate: #Predicate { $0.id == targetID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

struct SpeakerProfileSnapshot: Sendable, Identifiable {
    let id: UUID
    let name: String
    let embedding: [Float]
    let lastSeen: Date
    let voiceprintSpace: String
    let sampleCount: Int

    init(profile: SpeakerProfile) {
        self.id = profile.id
        self.name = profile.name
        self.embedding = profile.embedding
        self.lastSeen = profile.lastSeen
        self.voiceprintSpace = profile.voiceprintSpace
        self.sampleCount = profile.sampleCount
    }
}
