import FluidAudio
import Foundation

struct SpeakerMatcher {
    let threshold: Float

    init(threshold: Float = 0.28) {
        self.threshold = threshold
    }

    func findBestMatch(for embedding: [Float], in profiles: [SpeakerProfile]) -> SpeakerProfile? {
        guard !embedding.isEmpty, !profiles.isEmpty else {
            return nil
        }

        var bestMatch: SpeakerProfile?
        var bestDistance = threshold

        for profile in profiles {
            guard !profile.embedding.isEmpty, profile.embedding.count == embedding.count else {
                continue
            }

            let distance = SpeakerUtilities.cosineDistance(embedding, profile.embedding)
            if distance < bestDistance {
                bestDistance = distance
                bestMatch = profile
            } else if distance == bestDistance, let currentBest = bestMatch {
                if profile.lastSeen < currentBest.lastSeen {
                    bestMatch = profile
                }
            }
        }

        return bestMatch
    }
}
