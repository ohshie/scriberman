import Testing
import SwiftData
import FluidAudio
import Foundation
@testable import Scriberman

@Suite("Speaker Recognition Tests")
struct SpeakerRecognitionTests {
    private let container: ModelContainer
    private let store: SpeakerEmbeddingStore
    private let service: TranscriptionService

    init() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        self.container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        self.store = SpeakerEmbeddingStore(modelContainer: container)
        self.service = TranscriptionService(speakerEmbeddingStore: store)
    }

    @Test("Cross-session speaker recognition")
    func crossSessionRecognition() async throws {
        var aliceEmbedding: [Float] = Array(repeating: 0.0, count: 192)
        aliceEmbedding[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)
        
        var similarToAlice = aliceEmbedding
        similarToAlice[1] = 0.01 // Slight variation
        
        let diarizationResult = DiarizationResult(
            segments: [],
            speakerDatabase: ["cluster_2": similarToAlice]
        )
        
        let mapping = try await service.matchSpeakers(diarizationResult: diarizationResult)
        #expect(mapping["cluster_2"] == "Alice")
    }

    @Test("Multiple speakers recognition in same session")
    func multipleSpeakersRecognition() async throws {
        var aliceEmbedding: [Float] = Array(repeating: 0.0, count: 192)
        aliceEmbedding[0] = 1.0
        var bobEmbedding: [Float] = Array(repeating: 0.0, count: 192)
        bobEmbedding[1] = 1.0
        
        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)
        try await store.enrollSpeaker(name: "Bob", embedding: bobEmbedding)
        
        let diarizationResult = DiarizationResult(
            segments: [],
            speakerDatabase: [
                "local_id_1": aliceEmbedding,
                "local_id_2": bobEmbedding
            ]
        )
        
        let mapping = try await service.matchSpeakers(diarizationResult: diarizationResult)
        #expect(mapping["local_id_1"] == "Alice")
        #expect(mapping["local_id_2"] == "Bob")
    }

    @Test("Speaker profiles consistency in diarization pass")
    func speakerProfilesConsistencyInDiarizationPass() async throws {
        var aliceEmbedding: [Float] = Array(repeating: 0.0, count: 192)
        aliceEmbedding[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)
        
        let diarizationResult = DiarizationResult(
            segments: [
                TimedSpeakerSegment(speakerId: "cluster_1", embedding: [], startTimeSeconds: 0.0, endTimeSeconds: 2.0, qualityScore: 1.0),
                TimedSpeakerSegment(speakerId: "cluster_1", embedding: [], startTimeSeconds: 5.0, endTimeSeconds: 8.0, qualityScore: 1.0)
            ],
            speakerDatabase: ["cluster_1": aliceEmbedding]
        )
        
        let mapping = try await service.matchSpeakers(diarizationResult: diarizationResult)
        #expect(mapping["cluster_1"] == "Alice")
        
        let finalSpeakerIdForCluster1 = mapping["cluster_1"] ?? "cluster_1"
        #expect(finalSpeakerIdForCluster1 == "Alice")
    }
}
