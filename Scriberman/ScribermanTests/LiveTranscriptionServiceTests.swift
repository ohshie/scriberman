import Foundation
import FluidAudio
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

    @Test
    func prepareKeepsServiceUninitializedWhenVADInitializationFails() async throws {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))

        await service.prepareForTesting(
            workspace: workspace,
            initializeAsr: { _ in AsrManager(config: ASRConfig()) },
            initializeDiarizer: { _ in DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.5, minSpeechDuration: 0.5, minSilenceGap: 0.2)) },
            initializeVad: { _ in throw TestError.vadInitializationFailed }
        )

        #expect(await service.isInitialized == false)
    }

    @Test
    func processWithNoVADSpeechEventsDoesNotFlushToProcessChunk() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: false, event: nil)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { _, _, _ in
            await flushProbe.recordCall()
        }

        await service.process(samples: Array(repeating: 0.1, count: 4096), source: .mic, sampleRate: 16_000)

        #expect(await flushProbe.callCount() == 0)
    }

    @Test
    func speechEndFlushesAccumulatedBufferWithExpectedOffset() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { samples, source, offset in
            await flushProbe.recordCall(samplesCount: samples.count, source: source, offset: offset)
        }

        await service.process(samples: Array(repeating: 0.1, count: 8192), source: .mic, sampleRate: 16_000)

        #expect(await flushProbe.callCount() == 1)
        #expect(await flushProbe.lastSamplesCount() == 4096)
        #expect(await flushProbe.lastOffset() == 0)
        #expect(await flushProbe.lastSource() == .mic)
    }

    @Test
    func longContinuousSpeechTriggersThirtySecondCapFlush() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor(defaultTriggered: true, defaultEvent: nil)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { _, _, _ in
            await flushProbe.recordCall()
        }

        await service.process(samples: Array(repeating: 0.1, count: 500_000), source: .mic, sampleRate: 16_000)

        #expect(await flushProbe.callCount() > 0)
    }

    @Test
    func stopFlushesRemainingBufferedSpeech() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { _, _, _ in
            await flushProbe.recordCall()
        }

        await service.process(samples: Array(repeating: 0.1, count: 4096), source: .mic, sampleRate: 16_000)
        _ = await service.stop()

        #expect(await flushProbe.callCount() == 1)
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

private enum TestError: Error {
    case vadInitializationFailed
}

private actor FlushProbe {
    private var calls = 0
    private var lastSamples: Int?
    private var lastSourceValue: Scriberman.AudioSource?
    private var lastOffsetValue: Float?

    func recordCall(samplesCount: Int? = nil, source: Scriberman.AudioSource? = nil, offset: Float? = nil) {
        calls += 1
        if let samplesCount {
            lastSamples = samplesCount
        }
        if let source {
            lastSourceValue = source
        }
        if let offset {
            lastOffsetValue = offset
        }
    }

    func callCount() -> Int { calls }
    func lastSamplesCount() -> Int? { lastSamples }
    func lastSource() -> Scriberman.AudioSource? { lastSourceValue }
    func lastOffset() -> Float? { lastOffsetValue }
}

private actor MockVADProcessor: LiveVADStreamingProcessing {
    private var queued: [(triggered: Bool, event: LiveVADEventKind?)] = []
    private let defaultTriggered: Bool
    private let defaultEvent: LiveVADEventKind?

    init(defaultTriggered: Bool = false, defaultEvent: LiveVADEventKind? = nil) {
        self.defaultTriggered = defaultTriggered
        self.defaultEvent = defaultEvent
    }

    func enqueue(triggered: Bool, event: LiveVADEventKind?) {
        queued.append((triggered, event))
    }

    func processStreamingChunk(
        _ chunk: [Float],
        state: VadStreamState,
        config: VadSegmentationConfig
    ) async throws -> LiveVADProcessingResult {
        let next = queued.isEmpty ? (defaultTriggered, defaultEvent) : queued.removeFirst()
        return LiveVADProcessingResult(
            state: state,
            isTriggered: next.0,
            eventKind: next.1
        )
    }
}
