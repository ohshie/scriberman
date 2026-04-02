import Foundation
import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class LiveTranscriptionServiceTests: XCTestCase {
    private func makeStore() throws -> SpeakerEmbeddingStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        return SpeakerEmbeddingStore(modelContainer: container)
    }

    func testStopEnrollsNewSpeaker() async throws {
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
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.name, "Speaker 1")
    }

    func testStopEnrollsMultipleNewSpeakers() async throws {
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
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(Set(profiles.map(\.name)), ["Speaker 1", "Speaker 2"])
    }

    func testStopUpdatesLastSeenForMatchedSpeaker() async throws {
        let store = try makeStore()
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let aliceEmbedding = Array(repeating: Float(0.1), count: 256)

        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)
        let alice = try await store.fetchAllSnapshots().first { $0.name == "Alice" }
        let aliceID = try XCTUnwrap(alice?.id)

        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_0",
            embedding: aliceEmbedding,
            wasMatched: true,
            matchedProfileID: aliceID
        )

        _ = await service.stop()

        let profiles = try await store.fetchAllSnapshots()
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.name, "Alice")

        let updatedProfile = try await store.findProfileSnapshot(byID: aliceID)
        let updated = try XCTUnwrap(updatedProfile)
        XCTAssertGreaterThan(updated.lastSeen, oldDate)
    }

    func testStopSkipsEnrollmentForEmptyEmbedding() async throws {
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
        XCTAssertTrue(profiles.isEmpty)
    }

    func testStopWithoutStoreDoesNotCrash() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)

        await service.injectSessionSpeaker(
            id: "speaker_SPEAKER_0",
            embedding: Array(repeating: 0.5, count: 256),
            wasMatched: false,
            matchedProfileID: nil
        )

        _ = await service.stop()
    }

    func testMicAudioSourceMapsToMicrophoneASRSource() {
        let domainMic = AudioSource.mic
        let domainApp = AudioSource.app

        XCTAssertNotEqual(domainMic, domainApp)
        XCTAssertEqual(domainMic.rawValue, "mic")
        XCTAssertEqual(domainApp.rawValue, "app")
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
