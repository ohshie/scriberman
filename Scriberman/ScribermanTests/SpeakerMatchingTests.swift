import Testing
import SwiftData
import FluidAudio
import Foundation
@testable import Scriberman

@Suite("Speaker Matching Tests")
struct SpeakerMatchingTests {
    private let container: ModelContainer
    private let store: SpeakerEmbeddingStore
    private let service: TranscriptionService

    init() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        self.container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        self.store = SpeakerEmbeddingStore(modelContainer: container)
        self.service = TranscriptionService(speakerEmbeddingStore: store)
    }

    @Test("Match speakers with exact embedding")
    func matchSpeakersExactMatch() async throws {
        let aliceEmbedding: [Float] = Array(repeating: 0.1, count: 192)
        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)

        let diarizationResult = DiarizationResult(
            segments: [],
            speakerDatabase: ["cluster_1": aliceEmbedding]
        )

        let mapping = try await service.matchSpeakers(diarizationResult: diarizationResult)
        #expect(mapping["cluster_1"] == "Alice")
    }

    @Test("Match speakers with close embedding within threshold")
    func matchSpeakersCloseMatch() async throws {
        let aliceEmbedding: [Float] = Array(repeating: 0.1, count: 192)
        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)

        var closeEmbedding = aliceEmbedding
        closeEmbedding[0] = 0.11
        let diarizationResult = DiarizationResult(
            segments: [],
            speakerDatabase: ["cluster_1": closeEmbedding]
        )

        let mapping = try await service.matchSpeakers(diarizationResult: diarizationResult)
        #expect(mapping["cluster_1"] == "Alice")
    }

    @Test("Do not match speakers with embedding above threshold")
    func matchSpeakersNoMatchAboveThreshold() async throws {
        let aliceEmbedding: [Float] = Array(repeating: 0.1, count: 192)
        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)

        var differentEmbedding: [Float] = Array(repeating: 0.0, count: 192)
        differentEmbedding[0] = 1.0
        let diarizationResult = DiarizationResult(
            segments: [],
            speakerDatabase: ["cluster_2": differentEmbedding]
        )

        let mapping = try await service.matchSpeakers(diarizationResult: diarizationResult)
        #expect(mapping["cluster_2"] == nil)
    }

    @Test("Updating profile updates lastSeen date")
    func matchSpeakersUpdatesLastSeen() async throws {
        let aliceEmbedding: [Float] = Array(repeating: 0.1, count: 192)
        let oldDate = Date().addingTimeInterval(-3600)
        let profile = SpeakerProfile(name: "Alice", embedding: aliceEmbedding, lastSeen: oldDate)
        
        let context = ModelContext(container)
        context.insert(profile)
        try context.save()

        let diarizationResult = DiarizationResult(
            segments: [],
            speakerDatabase: ["cluster_1": aliceEmbedding]
        )

        _ = try await service.matchSpeakers(diarizationResult: diarizationResult)

        let updated = try await store.fetchAllSnapshots().first { $0.name == "Alice" }
        let verifiedUpdated = try #require(updated)
        #expect(verifiedUpdated.lastSeen > oldDate)
    }
}
