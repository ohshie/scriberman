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
}
