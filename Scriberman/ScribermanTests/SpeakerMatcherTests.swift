import FluidAudio
import Foundation
import Testing
@testable import Scriberman

struct SpeakerMatcherTests {
    /// A unit vector at `angle` radians in the first two dimensions. The cosine distance between
    /// two of them is `1 - cos(Δangle)`, so tests can place profiles at chosen distances.
    private static func vector(angle: Double, dimensions: Int = 8) -> [Float] {
        var vector = Array(repeating: Float(0), count: dimensions)
        vector[0] = Float(cos(angle))
        vector[1] = Float(sin(angle))
        return vector
    }

    /// The angle whose vector is at cosine distance `distance` from `vector(angle: 0)`.
    private static func angle(forDistance distance: Double) -> Double {
        acos(1 - distance)
    }

    private static func profile(
        _ name: String,
        atDistance distance: Double,
        voiceprintSpace: String = VoiceprintSpace.current
    ) -> SpeakerProfileSnapshot {
        SpeakerProfileSnapshot(profile: SpeakerProfile(
            name: name,
            embedding: vector(angle: angle(forDistance: distance)),
            voiceprintSpace: voiceprintSpace
        ))
    }

    private static let query = vector(angle: 0)
    private static let silent = SpeakerMatcher(log: { _ in })

    // MARK: - Threshold

    @Test
    func singleProfileWithinThresholdMatches() {
        let alice = Self.profile("Alice", atDistance: 0.25)
        #expect(Self.silent.findBestMatch(for: Self.query, in: [alice])?.name == "Alice")
    }

    @Test
    func singleProfileOutsideThresholdDoesNotMatch() {
        let alice = Self.profile("Alice", atDistance: 0.45)
        #expect(Self.silent.findBestMatch(for: Self.query, in: [alice]) == nil)
    }

    /// The threshold is inclusive.
    @Test
    func distanceExactlyAtThresholdMatches() {
        let stored = Self.vector(angle: 0.9)
        let distance = SpeakerUtilities.cosineDistance(Self.query, stored)
        let alice = SpeakerProfileSnapshot(profile: SpeakerProfile(name: "Alice", embedding: stored))

        let atBoundary = SpeakerMatcher(threshold: distance, log: { _ in })
        let justInside = SpeakerMatcher(threshold: distance.nextDown, log: { _ in })

        #expect(atBoundary.findBestMatch(for: Self.query, in: [alice])?.name == "Alice")
        #expect(justInside.findBestMatch(for: Self.query, in: [alice]) == nil)
    }

    @Test
    func emptyProfilesMatchNothing() {
        #expect(Self.silent.findBestMatch(for: Self.query, in: [SpeakerProfileSnapshot]()) == nil)
    }

    // MARK: - Margin

    @Test
    func closeRunnerUpPreventsMatch() {
        let alice = Self.profile("Alice", atDistance: 0.30)
        let bob = Self.profile("Bob", atDistance: 0.35)
        #expect(Self.silent.findBestMatch(for: Self.query, in: [alice, bob]) == nil)
    }

    /// The margin is inclusive.
    @Test
    func marginExactlyAtBoundaryMatches() {
        let alice = SpeakerProfileSnapshot(profile: SpeakerProfile(name: "Alice", embedding: Self.vector(angle: 0.5)))
        let bob = SpeakerProfileSnapshot(profile: SpeakerProfile(name: "Bob", embedding: Self.vector(angle: 0.8)))
        let aliceDistance = SpeakerUtilities.cosineDistance(Self.query, alice.embedding)
        let bobDistance = SpeakerUtilities.cosineDistance(Self.query, bob.embedding)

        let atBoundary = SpeakerMatcher(margin: bobDistance - aliceDistance, log: { _ in })
        let justOver = SpeakerMatcher(margin: (bobDistance - aliceDistance).nextUp, log: { _ in })

        #expect(atBoundary.findBestMatch(for: Self.query, in: [alice, bob])?.name == "Alice")
        #expect(justOver.findBestMatch(for: Self.query, in: [alice, bob]) == nil)
    }

    /// Two equally close profiles have zero margin, so neither matches.
    @Test
    func tieMatchesNothing() {
        let embedding = Self.vector(angle: 0.3)
        let older = SpeakerProfileSnapshot(profile: SpeakerProfile(
            name: "Older", embedding: embedding, lastSeen: Date(timeIntervalSince1970: 1_000)
        ))
        let newer = SpeakerProfileSnapshot(profile: SpeakerProfile(
            name: "Newer", embedding: embedding, lastSeen: Date(timeIntervalSince1970: 2_000)
        ))
        #expect(Self.silent.findBestMatch(for: Self.query, in: [older, newer]) == nil)
    }

    // MARK: - Voiceprint space

    @Test
    func profileFromAnotherSpaceIsIgnored() {
        let alice = Self.profile("Alice", atDistance: 0.05, voiceprintSpace: "community-1")
        #expect(Self.silent.findBestMatch(for: Self.query, in: [alice]) == nil)
    }

    /// A profile from another space neither matches nor counts as a runner-up.
    @Test
    func profileFromAnotherSpaceDoesNotBlockMargin() {
        let alice = Self.profile("Alice", atDistance: 0.20)
        let legacy = Self.profile("Legacy", atDistance: 0.21, voiceprintSpace: "")
        #expect(Self.silent.findBestMatch(for: Self.query, in: [alice, legacy])?.name == "Alice")
    }

    // MARK: - Exclusive assignment

    /// Spec scenario "Two speakers of one source want the same profile".
    @Test
    func twoSpeakersWantingOneProfileAreResolvedExclusively() {
        let alice = Self.vector(angle: 0)
        let bob = Self.vector(angle: 1.2)
        let others = Self.vector(angle: -2.0)
        let profiles = [
            SpeakerProfileSnapshot(profile: SpeakerProfile(name: "Alice", embedding: alice)),
            SpeakerProfileSnapshot(profile: SpeakerProfile(name: "Bob", embedding: bob)),
            SpeakerProfileSnapshot(profile: SpeakerProfile(name: "Carol", embedding: others))
        ]
        // First speaker: close to Alice only. Second: 0.30 from Alice and 0.38 from Bob, which
        // fails the margin while Alice is available and passes once Alice is taken.
        let first = Self.vector(angle: -Self.angle(forDistance: 0.20))
        let second = Self.secondSpeaker(aliceDistance: 0.30, bobDistance: 0.38, alice: alice, bob: bob)

        let result = Self.silent.assign(
            [(label: "mic_0", embedding: first), (label: "mic_1", embedding: second)],
            to: profiles
        )

        #expect(result["mic_0"]?.name == "Alice")
        #expect(result["mic_1"]?.name == "Bob")
    }

    @Test
    func assignmentLeavesLoserUnmatchedWhenNoRunnerUpQualifies() {
        let profiles = [Self.profile("Alice", atDistance: 0)]
        let closer = Self.vector(angle: Self.angle(forDistance: 0.10))
        let farther = Self.vector(angle: -Self.angle(forDistance: 0.20))

        let result = Self.silent.assign(
            [(label: "mic_0", embedding: farther), (label: "mic_1", embedding: closer)],
            to: profiles
        )

        #expect(result["mic_1"]?.name == "Alice")
        #expect(result["mic_0"] == nil)
    }

    // MARK: - Decision log

    @Test
    func everyDecisionIsLoggedWithTopTwoDistances() {
        let lines = LockedLines()
        let matcher = SpeakerMatcher(log: { lines.append($0) })
        let alice = Self.profile("Alice", atDistance: 0.10)
        let bob = Self.profile("Bob", atDistance: 0.60)
        let far = Self.vector(angle: .pi)

        _ = matcher.assign(
            [(label: "mic_0", embedding: Self.query), (label: "mic_1", embedding: far)],
            to: [alice, bob]
        )

        let logged = lines.values
        #expect(logged.count == 2)
        let matched = logged.first { $0.contains("[mic_0]") } ?? ""
        #expect(matched.contains("matched \(alice.id.uuidString)"))
        #expect(matched.contains("\(alice.id.uuidString)=0.100"))
        #expect(matched.contains("\(bob.id.uuidString)=0.600"))
        #expect(!matched.contains("Alice"))
        let unmatched = logged.first { $0.contains("[mic_1]") } ?? ""
        #expect(unmatched.contains("unmatched"))
    }

    // MARK: - Helpers

    /// A unit vector at the requested distances from `alice` and `bob`, solved in 3 dimensions.
    private static func secondSpeaker(aliceDistance: Double, bobDistance: Double, alice: [Float], bob: [Float]) -> [Float] {
        // q = a·x + b·y + c·z with x = alice, y ⟂ x in the alice/bob plane, z orthogonal.
        let cosAB = Double(1 - SpeakerUtilities.cosineDistance(alice, bob))
        let sinAB = (1 - cosAB * cosAB).squareRoot()
        let a = 1 - aliceDistance
        let b = ((1 - bobDistance) - a * cosAB) / sinAB
        let c = max(0, 1 - a * a - b * b).squareRoot()
        var result = Array(repeating: Float(0), count: alice.count)
        // x = (1, 0, …) and y = (0, 1, …): alice is at angle 0 and bob at a positive angle.
        result[0] = Float(a)
        result[1] = Float(b)
        result[2] = Float(c)
        return result
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
    }

    var values: [String] {
        lock.withLock { lines }
    }
}
