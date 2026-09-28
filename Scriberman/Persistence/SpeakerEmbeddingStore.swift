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

    func findProfileSnapshot(byID id: UUID) throws -> SpeakerProfileSnapshot? {
        try SpeakerProfile.fetch(id: id, in: modelContext).map(SpeakerProfileSnapshot.init(profile:))
    }

    /// The stored profile `matcher` picks for `embedding`, or `nil` when none qualifies.
    ///
    /// Delegates to `SpeakerMatcher`, so live and offline transcription apply the same boundary
    /// and tie rule.
    func findBestMatchSnapshot(
        embedding: [Float],
        matcher: SpeakerMatcher = SpeakerMatcher()
    ) -> SpeakerProfileSnapshot? {
        guard let profiles = try? fetchAllSnapshots() else { return nil }
        return matcher.findBestMatch(for: embedding, in: profiles)
    }

    // MARK: - Enrollment

    /// Creates a profile for a voice no existing profile matched, labelled `Speaker N` with N one
    /// more than the highest number in any existing `Speaker <number>` label.
    ///
    /// Always inserts. Automatic enrollment used to update any profile with the generated name,
    /// so a numbering gap after a deletion overwrote an existing speaker's voiceprint.
    @discardableResult
    func enrollNewSpeaker(embedding: [Float]) throws -> UUID {
        let label = Self.nextAutomaticLabel(after: try fetchAll().map(\.name))
        return try insertProfile(name: label, embedding: embedding)
    }

    /// Creates a profile with a name the user chose.
    @discardableResult
    func enrollNamedSpeaker(name: String, embedding: [Float]) throws -> UUID {
        try insertProfile(name: name, embedding: embedding)
    }

    /// Replaces one profile's voiceprint and marks it seen now.
    func updateEmbedding(profileID: UUID, embedding: [Float]) throws {
        guard let profile = try SpeakerProfile.fetch(id: profileID, in: modelContext) else { return }
        profile.embedding = embedding
        profile.lastSeen = .now
        try modelContext.save()
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

    /// `Speaker <max N + 1>` over the labels of the form `Speaker <number>`, or `Speaker 1`.
    static func nextAutomaticLabel(after labels: [String]) -> String {
        let highest = labels.compactMap { label -> Int? in
            guard label.hasPrefix("Speaker ") else { return nil }
            let number = label.dropFirst("Speaker ".count)
            guard !number.isEmpty, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber) else { return nil }
            return Int(number)
        }.max() ?? 0
        return "Speaker \(highest + 1)"
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
