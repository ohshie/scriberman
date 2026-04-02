import Accelerate
import Foundation
import SwiftData

actor SpeakerEmbeddingStore {
    private let modelContainer: ModelContainer
    private let context: ModelContext

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.context = ModelContext(modelContainer)
    }

    func fetchAll() throws -> [SpeakerProfile] {
        let descriptor = FetchDescriptor<SpeakerProfile>()
        return try context.fetch(descriptor).sorted(by: { $0.lastSeen > $1.lastSeen })
    }

    func fetchAllSnapshots() throws -> [SpeakerProfileSnapshot] {
        try fetchAll().map(SpeakerProfileSnapshot.init(profile:))
    }

    func save(_ profile: SpeakerProfile) throws {
        context.insert(profile)
        try context.save()
    }

    func updateProfile(id: UUID) throws {
        let descriptor = FetchDescriptor<SpeakerProfile>()
        let profiles = try context.fetch(descriptor)
        var profileToUpdate: SpeakerProfile?
        for profile in profiles where profile.id == id {
            profileToUpdate = profile
            break
        }
        if let profile = profileToUpdate {
            profile.lastSeen = .now
            try context.save()
        }
    }

    func delete(_ profile: SpeakerProfile) throws {
        let id = profile.persistentModelID
        if let toDelete = context.model(for: id) as? SpeakerProfile {
            context.delete(toDelete)
            try context.save()
        }
    }

    func deleteProfile(id: UUID) throws {
        let descriptor = FetchDescriptor<SpeakerProfile>()
        let profiles = try context.fetch(descriptor)
        if let profile = profiles.first(where: { $0.id == id }) {
            context.delete(profile)
            try context.save()
        }
    }

    func findProfile(byID id: UUID) throws -> SpeakerProfile? {
        let descriptor = FetchDescriptor<SpeakerProfile>()
        let profiles = try context.fetch(descriptor)
        for profile in profiles where profile.id == id {
            return profile
        }
        return nil
    }

    func findProfileSnapshot(byID id: UUID) throws -> SpeakerProfileSnapshot? {
        guard let profile = try findProfile(byID: id) else {
            return nil
        }
        return SpeakerProfileSnapshot(profile: profile)
    }

    /// Finds the stored `SpeakerProfile` whose embedding has the highest cosine similarity
    /// to `embedding`, returning it if similarity ≥ `threshold`.
    ///
    /// Uses Accelerate-based dot product of L2-normalised vectors.
    ///
    /// - Parameters:
    ///   - embedding: The query embedding (need not be pre-normalised).
    ///   - threshold: Minimum cosine similarity to count as a match. Default: 0.72.
    /// - Returns: The best-matching profile, or `nil` if the store is empty, the query
    ///   embedding is zero-length / all-zeros, or no profile meets the threshold.
    func findBestMatch(embedding: [Float], threshold: Float = 0.72) -> SpeakerProfile? {
        // task 5.2: handle empty/zero embeddings gracefully
        guard !embedding.isEmpty else { return nil }

        guard let profiles = try? fetchAll(), !profiles.isEmpty else { return nil }

        // L2-normalise the query
        let queryNorm = l2Norm(embedding)
        guard queryNorm > 0 else { return nil }

        var normalizedQuery = embedding
        var invQueryNorm = 1.0 / queryNorm
        vDSP_vsmul(embedding, 1, &invQueryNorm, &normalizedQuery, 1, vDSP_Length(embedding.count))

        var bestProfile: SpeakerProfile?
        var bestSimilarity: Float = -Float.infinity

        for profile in profiles {
            guard !profile.embedding.isEmpty,
                  profile.embedding.count == embedding.count else { continue }

            let profileNorm = l2Norm(profile.embedding)
            guard profileNorm > 0 else { continue }

            var normalizedProfile = profile.embedding
            var invProfileNorm = 1.0 / profileNorm
            vDSP_vsmul(profile.embedding, 1, &invProfileNorm, &normalizedProfile, 1, vDSP_Length(profile.embedding.count))

            // Cosine similarity = dot product of L2-normalised vectors
            var similarity: Float = 0.0
            vDSP_dotpr(normalizedQuery, 1, normalizedProfile, 1, &similarity, vDSP_Length(normalizedQuery.count))

            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestProfile = profile
            }
        }

        guard bestSimilarity >= threshold else { return nil }
        return bestProfile
    }

    func findBestMatchSnapshot(embedding: [Float], threshold: Float = 0.72) -> SpeakerProfileSnapshot? {
        guard let match = findBestMatch(embedding: embedding, threshold: threshold) else {
            return nil
        }
        return SpeakerProfileSnapshot(profile: match)
    }

    // MARK: - Private helpers

    private func l2Norm(_ v: [Float]) -> Float {
        var sumOfSquares: Float = 0
        vDSP_svesq(v, 1, &sumOfSquares, vDSP_Length(v.count))
        return sqrt(sumOfSquares)
    }

    func enrollSpeaker(name: String, embedding: [Float]) throws {
        let descriptor = FetchDescriptor<SpeakerProfile>()
        let allProfiles = try context.fetch(descriptor)
        
        if let existing = allProfiles.first(where: { $0.name.lowercased() == name.lowercased() }) {
            existing.embedding = embedding
            existing.lastSeen = .now
        } else {
            let newProfile = SpeakerProfile(name: name, embedding: embedding)
            context.insert(newProfile)
        }
        
        try context.save()
    }
}
