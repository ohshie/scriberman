import Testing
import SwiftData
import FluidAudio
import Foundation
@testable import Scriberman

@Suite("SpeakerEmbeddingStore Tests")
struct SpeakerEmbeddingStoreTests {
    private let container: ModelContainer
    private let store: SpeakerEmbeddingStore

    init() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        self.container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        self.store = SpeakerEmbeddingStore(modelContainer: container)
    }

    @Test("Fetch a profile by ID beyond the first 1,000 rows of an on-disk store")
    func fetchProfileByIDBeyondFirstThousand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let onDiskContainer = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
        )
        let context = ModelContext(onDiskContainer)
        var insertedIDs: [UUID] = []
        for index in 0..<1_500 {
            let profile = SpeakerProfile(name: "Speaker \(index)", embedding: [Float(index)])
            context.insert(profile)
            insertedIDs.append(profile.id)
        }
        try context.save()

        let targetID = insertedIDs[1_400]
        let fetched = try SpeakerProfile.fetch(id: targetID, in: ModelContext(onDiskContainer))

        #expect(fetched?.id == targetID)
        #expect(fetched?.name == "Speaker 1400")
    }

    // MARK: - Voiceprint space reset

    private func isolatedDefaults() -> UserDefaults {
        let suite = "SpeakerEmbeddingStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Start-up reset deletes every profile when no voiceprint space is recorded")
    func resetDeletesProfilesOnMissingMarker() throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0], voiceprintSpace: ""))
        context.insert(SpeakerProfile(name: "Bob", embedding: [0, 1]))
        try context.save()
        let defaults = isolatedDefaults()

        let removed = try SpeakerProfile.resetIfVoiceprintSpaceChanged(in: context, userDefaults: defaults)

        #expect(removed == 2)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SpeakerProfile>()).isEmpty)
        #expect(defaults.string(forKey: SpeakerProfile.voiceprintSpaceMarkerKey) == VoiceprintSpace.current)
    }

    @Test("Start-up reset deletes every profile when another voiceprint space is recorded")
    func resetDeletesProfilesOnOtherSpace() throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0]))
        try context.save()
        let defaults = isolatedDefaults()
        defaults.set("community-1", forKey: SpeakerProfile.voiceprintSpaceMarkerKey)

        let removed = try SpeakerProfile.resetIfVoiceprintSpaceChanged(in: context, userDefaults: defaults)

        #expect(removed == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SpeakerProfile>()).isEmpty)
    }

    @Test("Start-up reset keeps profiles when the recorded voiceprint space is current")
    func resetKeepsProfilesOnCurrentSpace() throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0]))
        try context.save()
        let defaults = isolatedDefaults()
        defaults.set(VoiceprintSpace.current, forKey: SpeakerProfile.voiceprintSpaceMarkerKey)

        let removed = try SpeakerProfile.resetIfVoiceprintSpaceChanged(in: context, userDefaults: defaults)

        #expect(removed == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SpeakerProfile>()).map(\.name) == ["Alice"])
    }

    @Test("Enroll a new speaker")
    func enrollNewSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAllSnapshots()
        #expect(all.count == 1)
        #expect(all.first?.name == "Alice")
        #expect(all.first?.embedding == embedding)
    }

    // MARK: - Folding voiceprints (renames)

    @Test("Folding into a new name creates a profile with one voiceprint")
    func foldCreatesProfile() async throws {
        let alice = try await store.enrollNamedSpeaker(name: "Alice", embedding: Array(repeating: 0.1, count: 4))

        try await store.foldVoiceprint(name: "Bob", embedding: [0, 1, 0, 0])

        let all = try await store.fetchAllSnapshots()
        #expect(Set(all.map(\.name)) == ["Alice", "Bob"])
        let bob = try #require(all.first { $0.name == "Bob" })
        #expect(bob.embedding == [0, 1, 0, 0])
        #expect(bob.sampleCount == 1)
        #expect(bob.voiceprintSpace == VoiceprintSpace.current)
        #expect(all.first { $0.id == alice }?.embedding == Array(repeating: 0.1, count: 4))
    }

    @Test("Folding into an existing name (case-insensitive) takes the running mean")
    func foldIntoExistingNameTakesRunningMean() async throws {
        let alice = try await store.enrollNamedSpeaker(name: "Alice", embedding: [1, 0, 0])
        try await store.foldVoiceprint(name: "Alice", embedding: [0, 1, 0])

        // Stored mean (1/2, 1/2, 0) with weight 2 and a new voiceprint with weight 1.
        try await store.foldVoiceprint(name: "alice", embedding: [0, 0, 1])

        let all = try await store.fetchAllSnapshots()
        #expect(all.count == 1)
        let profile = try #require(all.first)
        #expect(profile.id == alice)
        #expect(profile.name == "Alice")
        #expect(profile.sampleCount == 3)
        for (value, expected) in zip(profile.embedding, [Float(1) / 3, Float(1) / 3, Float(1) / 3]) {
            #expect(abs(value - expected) < 1e-6)
        }
    }

    /// Spec scenario "Fold order does not matter": three distinct normalised voiceprints folded in
    /// every order, with the store reopened between folds, give the same stored mean and count.
    @Test("Fold order does not matter across saves and reloads")
    func foldOrderDoesNotMatter() async throws {
        let voiceprints: [[Float]] = [
            [1, 0, 0],
            [0.6, 0.8, 0],
            [0, 0.28, 0.96]
        ]
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        var results: [(embedding: [Float], count: Int)] = []

        for order in orders {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("store.sqlite")
            for index in order {
                // A fresh container per fold: the stored vector is read back from disk each time.
                let onDisk = SpeakerEmbeddingStore(modelContainer: try ModelContainer(
                    for: SpeakerProfile.self,
                    configurations: ModelConfiguration(url: url)
                ))
                try await onDisk.foldVoiceprint(name: "Alice", embedding: voiceprints[index])
            }
            let reopened = SpeakerEmbeddingStore(modelContainer: try ModelContainer(
                for: SpeakerProfile.self,
                configurations: ModelConfiguration(url: url)
            ))
            let profile = try #require(try await reopened.fetchAllSnapshots().first)
            results.append((profile.embedding, profile.sampleCount))
        }

        let expected: [Float] = [1.6 / 3, 1.08 / 3, 0.96 / 3]
        for result in results {
            #expect(result.count == 3)
            for (value, target) in zip(result.embedding, expected) {
                #expect(abs(value - target) < 1e-6)
            }
        }
    }

    @Test("Folding into a profile from another voiceprint space replaces its voiceprint")
    func foldIntoOtherSpaceProfileReplaces() async throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0], voiceprintSpace: "", sampleCount: 4))
        try context.save()

        try await store.foldVoiceprint(name: "Alice", embedding: [0, 1])

        let profile = try #require(try await store.fetchAllSnapshots().first)
        #expect(profile.embedding == [0, 1])
        #expect(profile.sampleCount == 1)
        #expect(profile.voiceprintSpace == VoiceprintSpace.current)
    }

    @Test("The store matches nothing on a tie, as SpeakerMatcher does")
    func findBestMatchTieMatchesNothing() async throws {
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0
        let first = try await store.enrollNamedSpeaker(name: "First", embedding: embedding)
        try await store.enrollNamedSpeaker(name: "Second", embedding: embedding)
        try await store.updateProfile(id: first)

        let match = await store.findBestMatchSnapshot(embedding: embedding)

        #expect(match == nil)
    }

    // MARK: - Concurrency

    @Test("Match, enroll and delete run concurrently on an on-disk store")
    func concurrentMatchEnrollDelete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let onDisk = SpeakerEmbeddingStore(modelContainer: try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
        ))
        let axis: [Float] = [1] + Array(repeating: 0, count: 255)
        let toDelete = try await (0..<20).asyncMap { _ in try await onDisk.enrollNamedSpeaker(name: "Doomed", embedding: axis) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<50 { _ = await onDisk.findBestMatchSnapshot(embedding: axis) }
            }
            group.addTask {
                for index in 1...20 { try await onDisk.enrollNamedSpeaker(name: "Speaker \(index)", embedding: axis) }
            }
            group.addTask {
                for id in toDelete { try await onDisk.deleteProfile(id: id) }
            }
            try await group.waitForAll()
        }

        let names = try await onDisk.fetchAllSnapshots().map(\.name)
        #expect(names.count == 20)
        #expect(!names.contains("Doomed"))
        #expect(Set(names) == Set((1...20).map { "Speaker \($0)" }))
    }

    @Test("Delete a speaker profile")
    func deleteSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAllSnapshots()
        let firstId = try #require(all.first?.id)
        try await store.deleteProfile(id: firstId)
        
        let allAfter = try await store.fetchAllSnapshots()
        #expect(allAfter.isEmpty)
    }

    @Test("Find a profile by ID")
    func findProfileByID() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: embedding)

        let all = try await store.fetchAllSnapshots()
        let id = try #require(all.first?.id)

        let found = try await store.findProfileSnapshot(byID: id)
        #expect(found != nil)
        #expect(found?.name == "Alice")
    }

    // MARK: - findBestMatch (task 6.1)

    @Test("findBestMatch returns matching profile when similarity meets threshold")
    func findBestMatchReturnsMatchAboveThreshold() async throws {
        // Normalised unit vector along first axis
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0
        try await store.enrollNamedSpeaker(name: "Alice", embedding: embedding)

        // Query is the same vector — cosine similarity == 1.0
        let match = await store.findBestMatchSnapshot(embedding: embedding)
        #expect(match?.name == "Alice")
    }

    @Test("findBestMatch returns nil when best similarity is below threshold")
    func findBestMatchReturnsNilBelowThreshold() async throws {
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        try await store.enrollNamedSpeaker(name: "Alice", embedding: alice)

        // Orthogonal vector — cosine similarity == 0.0
        var query: [Float] = Array(repeating: 0.0, count: 256)
        query[1] = 1.0

        let match = await store.findBestMatchSnapshot(embedding: query)
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil when store is empty")
    func findBestMatchReturnsNilForEmptyStore() async {
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0

        let match = await store.findBestMatchSnapshot(embedding: embedding)
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil for zero-length embedding")
    func findBestMatchReturnsNilForZeroLengthEmbedding() async throws {
        var stored: [Float] = Array(repeating: 0.0, count: 256)
        stored[0] = 1.0
        try await store.enrollNamedSpeaker(name: "Alice", embedding: stored)

        let match = await store.findBestMatchSnapshot(embedding: [])
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil for all-zeros embedding")
    func findBestMatchReturnsNilForZeroEmbedding() async throws {
        var stored: [Float] = Array(repeating: 0.0, count: 256)
        stored[0] = 1.0
        try await store.enrollNamedSpeaker(name: "Alice", embedding: stored)

        let zeroEmbedding: [Float] = Array(repeating: 0.0, count: 256)
        let match = await store.findBestMatchSnapshot(embedding: zeroEmbedding)
        #expect(match == nil)
    }

    @Test("findBestMatch returns the highest-similarity profile when multiple exist")
    func findBestMatchReturnsBestAmongMultiple() async throws {
        // Alice: unit vector on axis 0
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        try await store.enrollNamedSpeaker(name: "Alice", embedding: alice)

        // Bob: unit vector on axis 1
        var bob: [Float] = Array(repeating: 0.0, count: 256)
        bob[1] = 1.0
        try await store.enrollNamedSpeaker(name: "Bob", embedding: bob)

        // Query close to Alice (small perturbation on axis 0)
        var query: [Float] = Array(repeating: 0.0, count: 256)
        query[0] = 0.99
        query[1] = 0.01

        let match = await store.findBestMatchSnapshot(embedding: query)
        #expect(match?.name == "Alice")
    }

    @Test("Rename a profile keeps its voiceprint")
    func renameProfileKeepsVoiceprint() async throws {
        let id = try await store.enrollNamedSpeaker(name: "Speaker 5", embedding: [0.5, 0.5])

        try await store.renameProfile(id: id, name: "Bob")

        let profile = try await store.findProfileSnapshot(byID: id)
        #expect(profile?.name == "Bob")
        #expect(profile?.embedding == [0.5, 0.5])
        #expect(try await store.fetchAllSnapshots().count == 1)
    }

    @Test("Delete all profiles empties the store")
    func deleteAllProfilesEmptiesStore() async throws {
        try await store.enrollNamedSpeaker(name: "Alice", embedding: [0.1])
        try await store.enrollNamedSpeaker(name: "Bob", embedding: [0.2])

        try await store.deleteAllProfiles()

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test("A deleted profile is no longer matched")
    func deletedProfileIsNotMatched() async throws {
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        let aliceID = try await store.enrollNamedSpeaker(name: "Alice", embedding: alice)
        #expect(await store.findBestMatchSnapshot(embedding: alice)?.name == "Alice")

        try await store.deleteProfile(id: aliceID)

        #expect(await store.findBestMatchSnapshot(embedding: alice) == nil)
    }
}

@MainActor
struct SpeakerProfileListTests {
    private struct DeleteFailure: Error {}

    private func snapshot(_ name: String) -> SpeakerProfileSnapshot {
        SpeakerProfileSnapshot(profile: SpeakerProfile(name: name, embedding: [0.1]))
    }

    @Test
    func failedDeleteReloadsAndShowsFailureUntilADeleteSucceeds() async {
        let bob = snapshot("Bob")
        let list = SpeakerProfileList(fetch: { [bob] })

        await list.delete { throw DeleteFailure() }
        #expect(list.deleteFailed)
        #expect(list.profiles.map(\.name) == ["Bob"])
        #expect(list.isLoading == false)

        await list.delete {}
        #expect(list.deleteFailed == false)
    }

    @Test
    func successfulDeleteReloadsFromStorage() async throws {
        let container = try ModelContainer(for: SpeakerProfile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = SpeakerEmbeddingStore(modelContainer: container)
        let aliceID = try await store.enrollNamedSpeaker(name: "Alice", embedding: [0.1])
        try await store.enrollNamedSpeaker(name: "Bob", embedding: [0.2])
        let list = SpeakerProfileList(store: store)
        await list.load()

        await list.delete { try await store.deleteProfile(id: aliceID) }

        #expect(list.profiles.map(\.name) == ["Bob"])
        #expect(list.deleteFailed == false)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
