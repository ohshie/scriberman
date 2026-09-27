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

    @Test("Enroll a new speaker")
    func enrollNewSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAllSnapshots()
        #expect(all.count == 1)
        #expect(all.first?.name == "Alice")
        #expect(all.first?.embedding == embedding)
    }

    // MARK: - Automatic enrollment (numbering)

    @Test("A numbering gap after a deletion gets the next number, not a reused one")
    func enrollAfterNumberingGap() async throws {
        let speaker3Embedding: [Float] = Array(repeating: 0.3, count: 256)
        try await store.enrollNamedSpeaker(name: "Speaker 2", embedding: Array(repeating: 0.2, count: 256))
        let speaker3 = try await store.enrollNamedSpeaker(name: "Speaker 3", embedding: speaker3Embedding)

        try await store.enrollNewSpeaker(embedding: Array(repeating: 0.9, count: 256))

        let names = try await store.fetchAllSnapshots().map(\.name)
        #expect(Set(names) == ["Speaker 2", "Speaker 3", "Speaker 4"])
        #expect(try await store.findProfileSnapshot(byID: speaker3)?.embedding == speaker3Embedding)
    }

    @Test("A user label that looks automatic is never overwritten")
    func enrollAfterUserSpeakerSevenLabel() async throws {
        let userEmbedding: [Float] = Array(repeating: 0.7, count: 256)
        let seven = try await store.enrollNamedSpeaker(name: "Speaker 7", embedding: userEmbedding)

        try await store.enrollNewSpeaker(embedding: Array(repeating: 0.9, count: 256))

        let names = try await store.fetchAllSnapshots().map(\.name)
        #expect(Set(names) == ["Speaker 7", "Speaker 8"])
        #expect(try await store.findProfileSnapshot(byID: seven)?.embedding == userEmbedding)
    }

    @Test("Automatic labels start at 1 and ignore labels that are not Speaker <number>")
    func nextAutomaticLabel() {
        #expect(SpeakerEmbeddingStore.nextAutomaticLabel(after: []) == "Speaker 1")
        #expect(SpeakerEmbeddingStore.nextAutomaticLabel(after: ["Alice", "Speaker", "Speaker 2b", "speaker 9"]) == "Speaker 1")
        #expect(SpeakerEmbeddingStore.nextAutomaticLabel(after: ["Speaker 10", "Speaker 2"]) == "Speaker 11")
    }

    // MARK: - Manual rename enrollment

    @Test("Renaming to an existing name updates that profile's voiceprint")
    @MainActor
    func renameToExistingNameUpdatesProfile() async throws {
        let alice = try await store.enrollNamedSpeaker(name: "Alice", embedding: Array(repeating: 0.1, count: 256))
        let newEmbedding: [Float] = Array(repeating: 0.2, count: 256)

        try await TranscriptStudyView.enrollRenamedSpeaker(name: "alice", embedding: newEmbedding, in: store)

        let all = try await store.fetchAllSnapshots()
        #expect(all.count == 1)
        #expect(all.first?.id == alice)
        #expect(all.first?.name == "Alice")
        #expect(all.first?.embedding == newEmbedding)
    }

    @Test("Renaming to a new name creates a profile")
    @MainActor
    func renameToNewNameCreatesProfile() async throws {
        let alice = try await store.enrollNamedSpeaker(name: "Alice", embedding: Array(repeating: 0.1, count: 256))

        try await TranscriptStudyView.enrollRenamedSpeaker(name: "Bob", embedding: Array(repeating: 0.2, count: 256), in: store)

        let all = try await store.fetchAllSnapshots()
        #expect(Set(all.map(\.name)) == ["Alice", "Bob"])
        #expect(all.first { $0.id == alice }?.embedding == Array(repeating: 0.1, count: 256))
    }

    @Test("The store breaks a tie toward the profile seen least recently, as SpeakerMatcher does")
    func findBestMatchTieGoesToLeastRecentlySeen() async throws {
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0
        let first = try await store.enrollNamedSpeaker(name: "First", embedding: embedding)
        let second = try await store.enrollNamedSpeaker(name: "Second", embedding: embedding)
        try await store.updateProfile(id: first)

        let match = await store.findBestMatchSnapshot(embedding: embedding)

        #expect(match?.id == second)
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
                for _ in 0..<20 { try await onDisk.enrollNewSpeaker(embedding: axis) }
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
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
