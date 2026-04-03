import Foundation
import Testing
@testable import Scriberman

struct SpeakerMatcherTests {
    @Test
    func findBestMatchReturnsClosestWithinThreshold() {
        let matcher = SpeakerMatcher(threshold: 0.28)

        var aliceEmbedding = Array(repeating: Float(0), count: 192)
        aliceEmbedding[0] = 1
        var bobEmbedding = Array(repeating: Float(0), count: 192)
        bobEmbedding[1] = 1

        let profiles = [
            SpeakerProfile(name: "Alice", embedding: aliceEmbedding),
            SpeakerProfile(name: "Bob", embedding: bobEmbedding)
        ]

        var query = aliceEmbedding
        query[1] = 0.05

        let match = matcher.findBestMatch(for: query, in: profiles)
        #expect(match?.name == "Alice")
    }

    @Test
    func findBestMatchReturnsNilWhenAllAreOutsideThreshold() {
        let matcher = SpeakerMatcher(threshold: 0.28)

        var aliceEmbedding = Array(repeating: Float(0), count: 192)
        aliceEmbedding[0] = 1

        var query = Array(repeating: Float(0), count: 192)
        query[1] = 1

        let match = matcher.findBestMatch(
            for: query,
            in: [SpeakerProfile(name: "Alice", embedding: aliceEmbedding)]
        )

        #expect(match == nil)
    }

    @Test
    func findBestMatchReturnsNilForEmptyProfiles() {
        let matcher = SpeakerMatcher()
        let query = Array(repeating: Float(0), count: 192)

        #expect(matcher.findBestMatch(for: query, in: [SpeakerProfile]()) == nil)
    }

    @Test
    func findBestMatchBreaksTiesByOldestLastSeen() {
        let matcher = SpeakerMatcher(threshold: 0.28)

        var embedding = Array(repeating: Float(0), count: 192)
        embedding[0] = 1

        let newer = SpeakerProfile(
            name: "Newer",
            embedding: embedding,
            lastSeen: Date(timeIntervalSince1970: 2_000)
        )
        let older = SpeakerProfile(
            name: "Older",
            embedding: embedding,
            lastSeen: Date(timeIntervalSince1970: 1_000)
        )

        let match = matcher.findBestMatch(for: embedding, in: [newer, older])

        #expect(match?.name == "Older")
    }
}
