import Foundation
import Testing
@testable import Scriberman

struct SpeakerNameSuggestionsTests {
    private func profile(_ name: String, count: Int, space: String = VoiceprintSpace.current) -> SpeakerProfileSnapshot {
        SpeakerProfileSnapshot(profile: SpeakerProfile(name: name, embedding: [1], voiceprintSpace: space, sampleCount: count))
    }

    /// Spec scenario "Typo avoided by suggestion".
    @Test
    func containsMatchesCaseInsensitivelyThenNewProfile() {
        let rows = SpeakerNameSuggestions.rows(for: "ali", profiles: [profile("Alice", count: 12), profile("Alicia", count: 3), profile("Bob", count: 2)])

        #expect(rows == [.profile(name: "Alice", count: 12), .profile(name: "Alicia", count: 3), .newProfile(name: "ali")])
        #expect(rows.first?.name == "Alice")
    }

    /// Spec scenario "Exact name typed".
    @Test
    func exactNameHasNoNewProfileRow() {
        let rows = SpeakerNameSuggestions.rows(for: "alice", profiles: [profile("Alice", count: 12)])
        #expect(rows == [.profile(name: "Alice", count: 12)])
    }

    /// Spec scenario "No profiles match".
    @Test
    func noMatchOffersOnlyANewProfile() {
        #expect(SpeakerNameSuggestions.rows(for: "Zed", profiles: [profile("Alice", count: 1)]) == [.newProfile(name: "Zed")])
    }

    @Test
    func emptyTextSuggestsNothing() {
        #expect(SpeakerNameSuggestions.rows(for: "  ", profiles: [profile("Alice", count: 1)]).isEmpty)
    }

    @Test
    func profilesFromAnotherVoiceprintSpaceAreNotSuggested() {
        let rows = SpeakerNameSuggestions.rows(for: "ali", profiles: [profile("Alice", count: 1, space: "")])
        #expect(rows == [.newProfile(name: "ali")])
    }
}
