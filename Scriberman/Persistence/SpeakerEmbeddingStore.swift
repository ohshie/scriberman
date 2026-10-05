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

    // MARK: - Enrollment

    /// Creates a profile with a name the user chose.
    @discardableResult
    func enrollNamedSpeaker(name: String, embedding: [Float]) throws -> UUID {
        try insertProfile(name: name, embedding: embedding)
    }

    /// Teaches the profile named `name` (case-insensitive) one more voiceprint, or creates it.
    ///
    /// The stored vector is the unnormalised mean of every voiceprint folded in:
    /// `mean' = (mean · n + v) / (n + 1)`. Keeping the mean unnormalised makes the result exact and
    /// independent of the order of folds; matching uses cosine distance, which ignores length.
    /// - Returns: the profile's ID.
    @discardableResult
    func foldVoiceprint(name: String, embedding: [Float]) throws -> UUID {
        let target = name.lowercased()
        guard let profile = try fetchAll().first(where: { $0.name.lowercased() == target }) else {
            return try insertProfile(name: name, embedding: embedding)
        }
        let count = Float(max(profile.sampleCount, 1))
        if profile.voiceprintSpace == VoiceprintSpace.current, profile.embedding.count == embedding.count {
            profile.embedding = zip(profile.embedding, embedding).map { ($0 * count + $1) / (count + 1) }
            profile.sampleCount = Int(count) + 1
        } else {
            // A voiceprint from another space cannot be averaged with this one.
            profile.embedding = embedding
            profile.voiceprintSpace = VoiceprintSpace.current
            profile.sampleCount = 1
        }
        profile.lastSeen = .now
        try modelContext.save()
        return profile.id
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

    private func insertProfile(name: String, embedding: [Float]) throws -> UUID {
        let profile = SpeakerProfile(name: name, embedding: embedding)
        modelContext.insert(profile)
        try modelContext.save()
        return profile.id
    }
}
