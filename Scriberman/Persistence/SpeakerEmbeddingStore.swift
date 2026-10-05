import Foundation
import SwiftData

/// The cross-session voiceprint store.
///
/// A `@ModelActor`, so its `ModelContext` is used only on the actor's own executor. Every public
/// method takes and returns values — `SpeakerProfileSnapshot`, `UUID` — and never a live
/// `SpeakerProfile`, which must not cross the actor boundary.
@ModelActor
actor SpeakerEmbeddingStore {
    func fetchAllSnapshots() throws -> [SpeakerProfileSnapshot] {
        try fetchAll().map(SpeakerProfileSnapshot.init(profile:))
    }

    func updateProfile(id: UUID) throws {
        if let profile = try SpeakerProfile.fetch(id: id, in: modelContext) {
            profile.lastSeen = .now
            try modelContext.save()
        }
    }

    func deleteProfile(id: UUID) throws {
        if let profile = try SpeakerProfile.fetch(id: id, in: modelContext) {
            modelContext.delete(profile)
            try modelContext.save()
        }
    }

    /// Deletes every stored profile.
    func deleteAllProfiles() throws {
        for profile in try fetchAll() {
            modelContext.delete(profile)
        }
        try modelContext.save()
    }

    func findProfileSnapshot(byID id: UUID) throws -> SpeakerProfileSnapshot? {
        try SpeakerProfile.fetch(id: id, in: modelContext).map(SpeakerProfileSnapshot.init(profile:))
    }

    /// The stored profile `matcher` picks for `embedding`, or `nil` when none qualifies.
    ///
    /// Delegates to `SpeakerMatcher`, so live and offline transcription apply the same threshold
    /// and margin.
    func findBestMatchSnapshot(
        embedding: [Float],
        matcher: SpeakerMatcher = SpeakerMatcher()
    ) -> SpeakerProfileSnapshot? {
        guard let profiles = try? fetchAllSnapshots() else { return nil }
        return matcher.findBestMatch(for: embedding, in: profiles)
    }

    // MARK: - Teaching

    /// Teaches the profile named `name` (case-insensitive) the voiceprints of one speaker, or
    /// creates it. Voiceprints taught earlier from `source` are removed from every profile first,
    /// so renaming a speaker again moves its voiceprints instead of adding them twice.
    /// - Returns: the taught profile's ID.
    @discardableResult
    func teach(name: String, source: VoiceprintSource, voiceprints: [[Float]]) throws -> UUID {
        try removeVoiceprints(from: source)
        let id = try append(voiceprints, to: name, source: source)
        try modelContext.save()
        return id
    }

    /// Removes every voiceprint taught from `source`, deleting profiles left with none.
    func forget(source: VoiceprintSource) throws {
        try removeVoiceprints(from: source)
        try modelContext.save()
    }

    /// Records that speaker `from` was merged into speaker `to`: what `from` taught is removed, and
    /// when `to` is named, its profile `name` is taught `from`'s voiceprints under `to`'s source.
    /// `to`'s earlier voiceprints stay.
    func retarget(from: VoiceprintSource, to: VoiceprintSource, name: String?, voiceprints: [[Float]]) throws {
        try removeVoiceprints(from: from)
        if let name, !voiceprints.isEmpty {
            try append(voiceprints, to: name, source: to)
        }
        try modelContext.save()
    }

    /// Moves every voiceprint of profile `id` into profile `targetID` and deletes `id`. A voiceprint
    /// whose source the target already holds is dropped instead of added twice.
    func mergeProfile(id: UUID, into targetID: UUID) throws {
        guard id != targetID,
              let profile = try SpeakerProfile.fetch(id: id, in: modelContext),
              let target = try SpeakerProfile.fetch(id: targetID, in: modelContext)
        else { return }
        let targetSources = Set(target.voiceprints.compactMap(\.source))
        let voiceprints = profile.voiceprints
        // Emptied first, so deleting the profile cannot cascade to the moved voiceprints.
        profile.voiceprints = []
        for voiceprint in voiceprints {
            if let source = voiceprint.source, targetSources.contains(source) {
                modelContext.delete(voiceprint)
            } else {
                target.voiceprints.append(voiceprint)
            }
        }
        modelContext.delete(profile)
        recomputeCaches(target)
        try modelContext.save()
    }

    /// Removes one voiceprint, deleting its profile when it was the last one.
    func removeVoiceprint(id: UUID) throws {
        let targetID = id
        var descriptor = FetchDescriptor<SpeakerVoiceprint>(predicate: #Predicate { $0.id == targetID })
        descriptor.fetchLimit = 1
        guard let voiceprint = try modelContext.fetch(descriptor).first else { return }
        let profile = voiceprint.profile
        modelContext.delete(voiceprint)
        if let profile {
            removeOrRecompute(profile, removing: [voiceprint.id])
        }
        try modelContext.save()
    }

    /// The voiceprints of one profile, newest first.
    func voiceprintSnapshots(profileID: UUID) throws -> [SpeakerVoiceprintSnapshot] {
        guard let profile = try SpeakerProfile.fetch(id: profileID, in: modelContext) else { return [] }
        return profile.voiceprints
            .sorted { $0.createdAt > $1.createdAt }
            .map(SpeakerVoiceprintSnapshot.init(voiceprint:))
    }

    /// Gives one profile a new name; its voiceprint is unchanged.
    func renameProfile(id: UUID, name: String) throws {
        guard let profile = try SpeakerProfile.fetch(id: id, in: modelContext) else { return }
        profile.name = name
        try modelContext.save()
    }

    /// The profile whose name matches `name` case-insensitively, other than `excludedID`, for the
    /// manual rename path.
    func profileID(forName name: String, excluding excludedID: UUID? = nil) throws -> UUID? {
        let target = name.lowercased()
        return try fetchAll().first { $0.name.lowercased() == target && $0.id != excludedID }?.id
    }

    // MARK: - Private

    private func fetchAll() throws -> [SpeakerProfile] {
        try modelContext.fetch(FetchDescriptor<SpeakerProfile>()).sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Adds `voiceprints`, weight 1 each, to the profile named `name` (case-insensitive), creating
    /// it when none exists. Does not save.
    private func append(_ voiceprints: [[Float]], to name: String, source: VoiceprintSource) throws -> UUID {
        let target = name.lowercased()
        let profile: SpeakerProfile
        if let existing = try fetchAll().first(where: { $0.name.lowercased() == target }) {
            profile = existing
            if profile.voiceprintSpace != VoiceprintSpace.current {
                // Voiceprints from another space cannot be averaged with these.
                for voiceprint in profile.voiceprints {
                    modelContext.delete(voiceprint)
                }
                profile.voiceprints = []
                profile.voiceprintSpace = VoiceprintSpace.current
            }
        } else {
            profile = SpeakerProfile(name: name, embedding: [])
            modelContext.insert(profile)
        }
        for embedding in voiceprints {
            let voiceprint = SpeakerVoiceprint(embedding: embedding, source: source)
            modelContext.insert(voiceprint)
            profile.voiceprints.append(voiceprint)
        }
        profile.lastSeen = .now
        recomputeCaches(profile)
        return profile.id
    }

    /// Deletes every voiceprint taught from `source`, then each affected profile left with none.
    /// Does not save.
    private func removeVoiceprints(from source: VoiceprintSource) throws {
        let sessionID: UUID? = source.sessionID
        let pass: String? = source.pass.rawValue
        let speakerID: String? = source.speakerID
        let descriptor = FetchDescriptor<SpeakerVoiceprint>(predicate: #Predicate {
            $0.sourceSessionID == sessionID && $0.sourcePass == pass && $0.sourceSpeakerID == speakerID
        })
        let voiceprints = try modelContext.fetch(descriptor)
        var removedByProfile: [UUID: (profile: SpeakerProfile, ids: Set<UUID>)] = [:]
        for voiceprint in voiceprints {
            if let profile = voiceprint.profile {
                removedByProfile[profile.id, default: (profile, [])].ids.insert(voiceprint.id)
            }
            modelContext.delete(voiceprint)
        }
        for (profile, ids) in removedByProfile.values {
            removeOrRecompute(profile, removing: ids)
        }
    }

    /// Deletes `profile` when no voiceprint is left after removing `ids`, else refreshes its caches.
    private func removeOrRecompute(_ profile: SpeakerProfile, removing ids: Set<UUID>) {
        profile.voiceprints.removeAll { ids.contains($0.id) }
        if profile.voiceprints.isEmpty {
            modelContext.delete(profile)
        } else {
            recomputeCaches(profile)
        }
    }

    /// Sets the profile's cached `embedding` to the weighted mean of its voiceprints and
    /// `sampleCount` to the sum of their weights. Every voiceprint change goes through here, so the
    /// caches matching reads cannot drift from the voiceprints.
    private func recomputeCaches(_ profile: SpeakerProfile) {
        let voiceprints = profile.voiceprints
        guard let dimension = voiceprints.first?.embedding.count else {
            profile.embedding = []
            profile.sampleCount = 0
            return
        }
        var sum = [Float](repeating: 0, count: dimension)
        var total = 0
        for voiceprint in voiceprints where voiceprint.embedding.count == dimension {
            let weight = max(voiceprint.weight, 1)
            for index in 0..<dimension {
                sum[index] += voiceprint.embedding[index] * Float(weight)
            }
            total += weight
        }
        profile.embedding = sum.map { $0 / Float(total) }
        profile.sampleCount = total
    }
}
