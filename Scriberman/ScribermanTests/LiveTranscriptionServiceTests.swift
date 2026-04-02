import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
@Suite
struct LiveTranscriptionServiceTests {
    private func makeStore() throws -> SpeakerEmbeddingStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        return SpeakerEmbeddingStore(modelContainer: container)
    }

    @Test
    func stopEnrollsNewSpeaker() async throws {
        let store = try makeStore()
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_0",
            embedding: Array(repeating: 0.5, count: 256),
            wasMatched: false,
            matchedProfileID: nil
        )

        _ = await service.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Speaker 1")
    }

    @Test
    func stopEnrollsMultipleNewSpeakers() async throws {
        let store = try makeStore()
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_0",
            embedding: Array(repeating: 0.1, count: 256),
            wasMatched: false,
            matchedProfileID: nil
        )
        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_1",
            embedding: Array(repeating: 0.2, count: 256),
            wasMatched: false,
            matchedProfileID: nil
        )

        _ = await service.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.count == 2)
        #expect(Set(profiles.map(\.name)) == ["Speaker 1", "Speaker 2"])
    }

    @Test
    func stopUpdatesLastSeenForMatchedSpeaker() async throws {
        let store = try makeStore()
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let aliceEmbedding = Array(repeating: Float(0.1), count: 256)

        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)
        let alice = try await store.fetchAllSnapshots().first { $0.name == "Alice" }
        let aliceID = try #require(alice?.id)

        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_0",
            embedding: aliceEmbedding,
            wasMatched: true,
            matchedProfileID: aliceID
        )

        _ = await service.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Alice")

        let updatedProfile = try await store.findProfileSnapshot(byID: aliceID)
        let updated = try #require(updatedProfile)
        #expect(updated.lastSeen > oldDate)
    }

    @Test
    func stopSkipsEnrollmentForEmptyEmbedding() async throws {
        let store = try makeStore()
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_0",
            embedding: [],
            wasMatched: false,
            matchedProfileID: nil
        )

        _ = await service.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.isEmpty)
    }

    @Test
    func stopWithoutStoreDoesNotCrash() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)

        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_0",
            embedding: Array(repeating: 0.5, count: 256),
            wasMatched: false,
            matchedProfileID: nil
        )

        _ = await service.stop()
    }

    @Test
    func micAudioSourceMapsToMicrophoneASRSource() {
        let domainMic = AudioSource.mic
        let domainApp = AudioSource.app

        #expect(domainMic != domainApp)
        #expect(domainMic.rawValue == "mic")
        #expect(domainApp.rawValue == "app")
    }
}

extension LiveTranscriptionService {
    func injectSessionSpeaker(
        id: String,
        embedding: [Float],
        wasMatched: Bool,
        matchedProfileID: UUID?
    ) {
        sessionSpeakers[id] = (embedding: embedding, wasMatched: wasMatched, matchedProfileID: matchedProfileID)
    }
}
