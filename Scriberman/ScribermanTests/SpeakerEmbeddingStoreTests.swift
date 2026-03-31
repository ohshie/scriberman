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

    @Test("Enroll a new speaker")
    func enrollNewSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "Alice")
        #expect(all.first?.embedding == embedding)
    }

    @Test("Update an existing speaker's profile")
    func updateExistingSpeaker() async throws {
        let embedding1: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding1)
        
        let embedding2: [Float] = Array(repeating: 0.2, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding2)
        
        let all = try await store.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "Alice")
        #expect(all.first?.embedding == embedding2)
    }

    @Test("Delete a speaker profile")
    func deleteSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)
        
        let all = try await store.fetchAll()
        try await store.delete(all.first!)
        
        let allAfter = try await store.fetchAll()
        #expect(allAfter.isEmpty)
    }

    @Test("Find a profile by ID")
    func findProfileByID() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)

        let all = try await store.fetchAll()
        let id = try #require(all.first?.id)

        let found = try await store.findProfile(byID: id)
        #expect(found != nil)
        #expect(found?.name == "Alice")
    }

    // MARK: - findBestMatch (task 6.1)

    @Test("findBestMatch returns matching profile when similarity meets threshold")
    func findBestMatchReturnsMatchAboveThreshold() async throws {
        // Normalised unit vector along first axis
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)

        // Query is the same vector — cosine similarity == 1.0
        let match = await store.findBestMatch(embedding: embedding, threshold: 0.72)
        #expect(match?.name == "Alice")
    }

    @Test("findBestMatch returns nil when best similarity is below threshold")
    func findBestMatchReturnsNilBelowThreshold() async throws {
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: alice)

        // Orthogonal vector — cosine similarity == 0.0
        var query: [Float] = Array(repeating: 0.0, count: 256)
        query[1] = 1.0

        let match = await store.findBestMatch(embedding: query, threshold: 0.72)
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil when store is empty")
    func findBestMatchReturnsNilForEmptyStore() async {
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0

        let match = await store.findBestMatch(embedding: embedding)
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil for zero-length embedding")
    func findBestMatchReturnsNilForZeroLengthEmbedding() async throws {
        var stored: [Float] = Array(repeating: 0.0, count: 256)
        stored[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: stored)

        let match = await store.findBestMatch(embedding: [])
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil for all-zeros embedding")
    func findBestMatchReturnsNilForZeroEmbedding() async throws {
        var stored: [Float] = Array(repeating: 0.0, count: 256)
        stored[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: stored)

        let zeroEmbedding: [Float] = Array(repeating: 0.0, count: 256)
        let match = await store.findBestMatch(embedding: zeroEmbedding)
        #expect(match == nil)
    }

    @Test("findBestMatch returns the highest-similarity profile when multiple exist")
    func findBestMatchReturnsBestAmongMultiple() async throws {
        // Alice: unit vector on axis 0
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: alice)

        // Bob: unit vector on axis 1
        var bob: [Float] = Array(repeating: 0.0, count: 256)
        bob[1] = 1.0
        try await store.enrollSpeaker(name: "Bob", embedding: bob)

        // Query close to Alice (small perturbation on axis 0)
        var query: [Float] = Array(repeating: 0.0, count: 256)
        query[0] = 0.99
        query[1] = 0.01

        let match = await store.findBestMatch(embedding: query, threshold: 0.72)
        #expect(match?.name == "Alice")
    }
}
