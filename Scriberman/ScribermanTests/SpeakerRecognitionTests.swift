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
        try await store.enrollNamedSpeaker(name: "Alice", embedding: aliceEmbedding)
        
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
        
        try await store.enrollNamedSpeaker(name: "Alice", embedding: aliceEmbedding)
        try await store.enrollNamedSpeaker(name: "Bob", embedding: bobEmbedding)
        
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
        try await store.enrollNamedSpeaker(name: "Alice", embedding: aliceEmbedding)

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

    // MARK: - Live session speaker identities

    @Test("Identity record averages embeddings weighted by speech seconds")
    func identityRecordAccumulatesWeightedAverage() {
        var identity = SessionSpeakerIdentity()
        #expect(identity.averagedEmbedding.isEmpty)

        identity.accumulate(Array(repeating: 0.2, count: 192), seconds: 1)
        identity.accumulate(Array(repeating: 0.4, count: 192), seconds: 3)

        let averaged = identity.averagedEmbedding
        #expect(averaged.count == 192)
        #expect(abs(averaged[0] - 0.35) < 1e-5)
        #expect(identity.speechSeconds == 4)
    }

    @Test("Identity record ignores empty embeddings and zero durations")
    func identityRecordIgnoresEmptyInput() {
        var identity = SessionSpeakerIdentity()
        identity.accumulate([], seconds: 2)
        identity.accumulate([0.5], seconds: 0)
        #expect(identity.averagedEmbedding.isEmpty)
        #expect(identity.speechSeconds == 0)
    }

    @Test("An identity becomes matchable at three seconds of speech")
    func identityMatchableAtThreeSeconds() {
        var identity = SessionSpeakerIdentity()
        identity.accumulate([1, 0], seconds: 2.9)
        #expect(!identity.hasMatchableVoiceprint)
        identity.accumulate([1, 0], seconds: 0.1)
        #expect(identity.hasMatchableVoiceprint)
    }

    /// Spec scenario "Session with unknown voices".
    @Test("Stop creates no profile for unknown voices")
    func stopCreatesNoProfileForUnknownVoices() async throws {
        let liveService = LiveTranscriptionService(speakerEmbeddingStore: store)
        var mic = SessionSpeakerIdentity()
        mic.accumulate(Array(repeating: 0.2, count: 192), seconds: 4)
        var app = SessionSpeakerIdentity()
        app.accumulate(Array(repeating: -0.2, count: 192), seconds: 4)
        await liveService.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: mic)
        await liveService.injectSpeakerIdentityForTesting(source: .app, speakerIndex: 0, identity: app)

        let result = await liveService.stop()

        #expect(try await store.fetchAllSnapshots().isEmpty)
        #expect(Set(result.speakerEmbeddings.keys) == ["speaker_mic_0", "speaker_app_0"])
    }

    @Test("Stop refreshes lastSeen for a matched identity without creating profiles")
    func stopRefreshesLastSeenForMatchedIdentity() async throws {
        var aliceEmbedding: [Float] = Array(repeating: 0.0, count: 192)
        aliceEmbedding[0] = 1.0
        let context = ModelContext(container)
        let oldDate = Date(timeIntervalSinceNow: -3600)
        context.insert(SpeakerProfile(name: "Alice", embedding: aliceEmbedding, lastSeen: oldDate))
        try context.save()
        let aliceID = try #require(try await store.fetchAllSnapshots().first?.id)

        let liveService = LiveTranscriptionService(speakerEmbeddingStore: store)
        var identity = SessionSpeakerIdentity()
        identity.accumulate(aliceEmbedding, seconds: 5)
        await liveService.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity)

        let result = await liveService.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.map(\.name) == ["Alice"])
        let updated = try #require(try await store.findProfileSnapshot(byID: aliceID))
        #expect(updated.lastSeen > oldDate)
        #expect(updated.embedding == aliceEmbedding)
        #expect(result.speakerEmbeddings == ["Alice": aliceEmbedding])
    }

    @Test("Stop skips identities without enough speech")
    func stopSkipsIdentitiesWithoutEnoughSpeech() async throws {
        let liveService = LiveTranscriptionService(speakerEmbeddingStore: store)
        var short = SessionSpeakerIdentity()
        short.accumulate(Array(repeating: 0.2, count: 192), seconds: 2)
        await liveService.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: SessionSpeakerIdentity())
        await liveService.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 1, identity: short)

        let result = await liveService.stop()

        #expect(result.speakerEmbeddings.isEmpty)
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }
}
