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

    // MARK: - LS-EEND session speaker identities (task 5.2)

    @Test("Identity record accumulates embeddings and averages them")
    func identityRecordAccumulatesAndAverages() {
        var identity = SessionSpeakerIdentity()
        #expect(identity.averagedEmbedding.isEmpty)

        identity.accumulate(Array(repeating: 0.2, count: 192))
        identity.accumulate(Array(repeating: 0.4, count: 192))

        let averaged = identity.averagedEmbedding
        #expect(averaged.count == 192)
        #expect(abs(averaged[0] - 0.3) < 1e-4)
    }

    @Test("Identity record ignores empty embeddings and stays bound after accumulation")
    func identityRecordStaysBoundAfterAccumulation() {
        var identity = SessionSpeakerIdentity()
        identity.accumulate([])
        #expect(identity.averagedEmbedding.isEmpty)

        identity.boundProfileID = UUID()
        identity.boundProfileName = "Alice"
        identity.accumulate(Array(repeating: 0.5, count: 192))

        #expect(identity.isBound)
        #expect(identity.boundProfileName == "Alice")
    }

    @Test("Stop enrolls unbound identity record with averaged embedding")
    func stopEnrollsUnboundIdentityRecordWithAveragedEmbedding() async throws {
        let liveService = LiveTranscriptionService(speakerEmbeddingStore: store)

        var identity = SessionSpeakerIdentity()
        identity.accumulate(Array(repeating: 0.2, count: 192))
        identity.accumulate(Array(repeating: 0.4, count: 192))
        await liveService.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity)

        _ = await liveService.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Speaker 1")
        let embedding = try #require(profiles.first?.embedding)
        #expect(abs(embedding[0] - 0.3) < 1e-4)
    }

    @Test("Stop refreshes lastSeen for bound identity record without duplicating profiles")
    func stopRefreshesLastSeenForBoundIdentityRecord() async throws {
        let oldDate = Date(timeIntervalSinceNow: -3600)
        var aliceEmbedding: [Float] = Array(repeating: 0.0, count: 192)
        aliceEmbedding[0] = 1.0
        try await store.enrollSpeaker(name: "Alice", embedding: aliceEmbedding)
        let enrolledProfiles = try await store.fetchAllSnapshots()
        let aliceID = try #require(enrolledProfiles.first?.id)

        let liveService = LiveTranscriptionService(speakerEmbeddingStore: store)

        var identity = SessionSpeakerIdentity()
        identity.accumulate(aliceEmbedding)
        identity.boundProfileID = aliceID
        identity.boundProfileName = "Alice"
        await liveService.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity)

        _ = await liveService.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == "Alice")
        let updatedProfile = try await store.findProfileSnapshot(byID: aliceID)
        let updated = try #require(updatedProfile)
        #expect(updated.lastSeen > oldDate)
    }

    @Test("Stop skips identity records without embeddings")
    func stopSkipsEmbeddingLessIdentityRecords() async throws {
        let liveService = LiveTranscriptionService(speakerEmbeddingStore: store)

        await liveService.injectSpeakerIdentityForTesting(
            source: .mic,
            speakerIndex: 0,
            identity: SessionSpeakerIdentity()
        )

        _ = await liveService.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.isEmpty)
    }

    @Test("Stop enrolls one profile per identity record across sources")
    func stopEnrollsIdentityRecordsAcrossSources() async throws {
        let liveService = LiveTranscriptionService(speakerEmbeddingStore: store)

        var micIdentity = SessionSpeakerIdentity()
        micIdentity.accumulate(Array(repeating: 0.1, count: 192))
        await liveService.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: micIdentity)

        var appIdentity = SessionSpeakerIdentity()
        appIdentity.accumulate(Array(repeating: 0.9, count: 192))
        await liveService.injectSpeakerIdentityForTesting(source: .app, speakerIndex: 0, identity: appIdentity)

        _ = await liveService.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.count == 2)
        #expect(Set(profiles.map(\.name)) == ["Speaker 1", "Speaker 2"])
    }
}
