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
            initializeDiarizer: { _, _ in DiarizerManager(config: DiarizerConfig(clusteringThreshold: 0.5, minSpeechDuration: 0.5, minSilenceGap: 0.2)) },
            initializeVad: { _, _ in throw TestError.vadInitializationFailed }
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
        #expect(await flushProbe.lastSamplesCount() == 8192)
        #expect(await flushProbe.lastOffset() == 0)
        #expect(await flushProbe.lastSource() == .mic)
    }

    @Test
    func preRollAudioIsIncludedAtSpeechStart() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: false, event: nil)
        await processor.enqueue(triggered: false, event: nil)
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { samples, source, offset in
            await flushProbe.recordCall(samples: samples, source: source, offset: offset)
        }

        let samples = makeChunks([0.01, 0.02, 0.30, 0.40])
        await service.process(samples: samples, source: .mic, sampleRate: 16_000)

        let flushedSamples = await flushProbe.lastSamples()
        #expect(await flushProbe.callCount() == 1)
        #expect(flushedSamples?.count == 16_384)
        #expect(flushedSamples?.first == 0.01)
        #expect(flushedSamples?[4096] == 0.02)
        #expect(flushedSamples?[8192] == 0.30)
        #expect(await flushProbe.lastOffset() == 0)
    }

    @Test
    func partialPreRollAtSessionStartIsClampedToZero() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: false, event: nil)
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { samples, source, offset in
            await flushProbe.recordCall(samples: samples, source: source, offset: offset)
        }

        await service.process(samples: makeChunks([0.10, 0.20, 0.30]), source: .mic, sampleRate: 16_000)

        #expect(await flushProbe.callCount() == 1)
        #expect(await flushProbe.lastSamplesCount() == 12_288)
        #expect(await flushProbe.lastOffset() == 0)
    }

    @Test
    func preRollBufferResetsBetweenUtterances() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: false, event: nil)
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await processor.enqueue(triggered: false, event: nil)
        await processor.enqueue(triggered: false, event: nil)
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { samples, _, _ in
            await flushProbe.recordCall(samples: samples)
        }

        await service.process(samples: makeChunks([0.01, 0.11, 0.12, 0.21, 0.22, 0.31, 0.32]), source: .mic, sampleRate: 16_000)

        let allSamples = await flushProbe.allSamples()
        #expect(allSamples.count == 2)
        #expect(allSamples.last?.count == 16_384)
        #expect(allSamples.last?.first == 0.21)
        #expect(allSamples.last?[4096] == 0.22)
        #expect(allSamples.last?[8192] == 0.31)
    }

    @Test
    func adjustedPreRollOffsetClampsToPreviousSegmentEnd() async throws {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _ in
            ASRResult(text: "hello", confidence: 1.0, duration: 0.1, processingTime: 0.01)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await processor.enqueue(triggered: false, event: nil)
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in await service.transcriptStream {
                receivedSegments.append(segment)
                if receivedSegments.count == 2 {
                    break
                }
            }
        }

        await service.process(samples: makeChunks([0.10, 0.11, 0.20, 0.30, 0.31]), source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        let first = try #require(receivedSegments.first)
        let second = try #require(receivedSegments.dropFirst().first)
        #expect(abs(first.endTime - 0.512) < 0.001)
        #expect(abs(second.startTime - first.endTime) < 0.001)
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

    // MARK: - Confidence Gate Tests (task 3.2)

    @Test
    func lowConfidenceResultDiscardedWhenGateAboveZero() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.asrConfidenceGate = 0.30
        await service.setStoredConfigForTesting(config)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _ in
            ASRResult(text: "hello world", confidence: 0.15, duration: 1.0, processingTime: 0.1)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in await service.transcriptStream {
                receivedSegments.append(segment)
            }
        }

        let loudSamples = Array(repeating: Float(0.1), count: 8192)
        await service.process(samples: loudSamples, source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        #expect(receivedSegments.isEmpty)
    }

    @Test
    func confidenceGateDisabledPassesAllResults() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        // Default gate is 0.0 — all results pass
        await service.setStoredConfigForTesting(.defaults)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _ in
            ASRResult(text: "hello world", confidence: 0.05, duration: 1.0, processingTime: 0.1)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in await service.transcriptStream {
                receivedSegments.append(segment)
            }
        }

        let loudSamples = Array(repeating: Float(0.1), count: 8192)
        await service.process(samples: loudSamples, source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        #expect(receivedSegments.count == 1)
    }

    @Test
    func highConfidenceResultAboveGatePasses() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.asrConfidenceGate = 0.30
        await service.setStoredConfigForTesting(config)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _ in
            ASRResult(text: "hello world", confidence: 0.55, duration: 1.0, processingTime: 0.1)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in await service.transcriptStream {
                receivedSegments.append(segment)
            }
        }

        let loudSamples = Array(repeating: Float(0.1), count: 8192)
        await service.process(samples: loudSamples, source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        #expect(receivedSegments.count == 1)
    }

    // MARK: - Amplitude Gate Tests (task 4.2)

    @Test
    func nearSilentBufferDiscardedWhenAmplitudeGateAboveZero() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.asrAmplitudeGate = 0.01
        await service.setStoredConfigForTesting(config)

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { _, _, _ in
            await flushProbe.recordCall()
        }

        // Near-silent samples: peak amplitude ~ 0.003, below gate of 0.01
        let silentSamples = Array(repeating: Float(0.003), count: 8192)
        await service.process(samples: silentSamples, source: .mic, sampleRate: 16_000)

        #expect(await flushProbe.callCount() == 0)
    }

    @Test
    func bufferForwardedWhenAmplitudeGateIsZero() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        // Gate is 0.0 (default) — all buffers pass
        await service.setStoredConfigForTesting(.defaults)

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { _, _, _ in
            await flushProbe.recordCall()
        }

        let silentSamples = Array(repeating: Float(0.003), count: 8192)
        await service.process(samples: silentSamples, source: .mic, sampleRate: 16_000)

        #expect(await flushProbe.callCount() == 1)
    }

    @Test
    func bufferAboveAmplitudeGateProceeds() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.asrAmplitudeGate = 0.01
        await service.setStoredConfigForTesting(config)

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { _, _, _ in
            await flushProbe.recordCall()
        }

        // Samples with peak amplitude 0.05, well above gate of 0.01
        let loudSamples = Array(repeating: Float(0.05), count: 8192)
        await service.process(samples: loudSamples, source: .mic, sampleRate: 16_000)

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
    private var lastSampleValues: [Float]?
    private var sampleValues: [[Float]] = []
    private var lastSourceValue: Scriberman.AudioSource?
    private var lastOffsetValue: Float?

    func recordCall(samples: [Float]? = nil, samplesCount: Int? = nil, source: Scriberman.AudioSource? = nil, offset: Float? = nil) {
        calls += 1
        if let samples {
            lastSampleValues = samples
            sampleValues.append(samples)
            lastSamples = samples.count
        }
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
    func lastSamples() -> [Float]? { lastSampleValues }
    func allSamples() -> [[Float]] { sampleValues }
    func lastSource() -> Scriberman.AudioSource? { lastSourceValue }
    func lastOffset() -> Float? { lastOffsetValue }
}

private func makeChunks(_ values: [Float]) -> [Float] {
    values.flatMap { Array(repeating: $0, count: 4096) }
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
