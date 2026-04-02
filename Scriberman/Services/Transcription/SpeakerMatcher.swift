import FluidAudio
import Foundation

struct SpeakerMatcher {
    let threshold: Float

    init(threshold: Float = 0.28) {
        self.threshold = threshold
    }

    func findBestMatch(for embedding: [Float], in profiles: [SpeakerProfile]) -> SpeakerProfile? {
        findBestMatch(
            for: embedding,
            in: profiles,
            profileEmbedding: { $0.embedding },
            profileLastSeen: { $0.lastSeen }
        )
    }

    func findBestMatch(for embedding: [Float], in profiles: [SpeakerProfileSnapshot]) -> SpeakerProfileSnapshot? {
        findBestMatch(
            for: embedding,
            in: profiles,
            profileEmbedding: { $0.embedding },
            profileLastSeen: { $0.lastSeen }
        )
    }

    private func findBestMatch<T>(
        for embedding: [Float],
        in profiles: [T],
        profileEmbedding: (T) -> [Float],
        profileLastSeen: (T) -> Date
    ) -> T? {
        guard !embedding.isEmpty, !profiles.isEmpty else {
            return nil
        }

        var bestMatch: T?
        var bestDistance = threshold

        for profile in profiles {
            let profileEmbedding = profileEmbedding(profile)
            guard !profileEmbedding.isEmpty, profileEmbedding.count == embedding.count else {
                continue
            }

            let distance = SpeakerUtilities.cosineDistance(embedding, profileEmbedding)
            if distance < bestDistance {
                bestDistance = distance
                bestMatch = profile
            } else if distance == bestDistance, let currentBest = bestMatch {
                if profileLastSeen(profile) < profileLastSeen(currentBest) {
                    bestMatch = profile
                }
            }
        }

        return bestMatch
    }
}
