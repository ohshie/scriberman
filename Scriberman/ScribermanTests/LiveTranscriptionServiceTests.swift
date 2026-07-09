import CoreML
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
        await service.setAsrTranscribeHookForTesting { _, _, _ in
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

    @Test
    func consecutiveSegmentsFromOneSourceReuseMutatedDecoderState() async throws {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))

        let observedLayers = DecoderStateProbe()
        await service.setAsrTranscribeHookForTesting { _, _, state in
            observedLayers.record(layerCount: decoderLayerCount(in: state))
            state = try TdtDecoderState(decoderLayers: 1)
            return ASRResult(text: "hello", confidence: 1.0, duration: 0.1, processingTime: 0.01)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        await service.process(samples: makeChunks([0.10, 0.20, 0.30, 0.40]), source: .mic, sampleRate: 16_000)

        #expect(observedLayers.values() == [2, 1])
    }

    @Test
    func decoderStatesAreIndependentAcrossSources() async throws {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))

        let observed = DecoderStateBySourceProbe()
        await service.setAsrTranscribeHookForTesting { _, source, state in
            observed.record(source: source, layerCount: decoderLayerCount(in: state))
            if source == .mic {
                state = try TdtDecoderState(decoderLayers: 1)
            }
            return ASRResult(text: "hello", confidence: 1.0, duration: 0.1, processingTime: 0.01)
        }

        let micProcessor = MockVADProcessor()
        await micProcessor.enqueue(triggered: true, event: .speechStart)
        await micProcessor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(micProcessor)
        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)

        let appProcessor = MockVADProcessor()
        await appProcessor.enqueue(triggered: true, event: .speechStart)
        await appProcessor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(appProcessor)
        await service.process(samples: makeChunks([0.30, 0.40]), source: .app, sampleRate: 16_000)

        let calls = observed.calls()
        #expect(calls == [
            DecoderStateSourceCall(source: .mic, layerCount: 2),
            DecoderStateSourceCall(source: .app, layerCount: 2)
        ])
    }

    @Test
    func decoderStatesResetAfterStop() async throws {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))

        let observedLayers = DecoderStateProbe()
        await service.setAsrTranscribeHookForTesting { _, _, state in
            observedLayers.record(layerCount: decoderLayerCount(in: state))
            state = try TdtDecoderState(decoderLayers: 1)
            return ASRResult(text: "hello", confidence: 1.0, duration: 0.1, processingTime: 0.01)
        }

        let firstProcessor = MockVADProcessor()
        await firstProcessor.enqueue(triggered: true, event: .speechStart)
        await firstProcessor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(firstProcessor)
        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        _ = await service.stop()

        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        let secondProcessor = MockVADProcessor()
        await secondProcessor.enqueue(triggered: true, event: .speechStart)
        await secondProcessor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(secondProcessor)
        await service.process(samples: makeChunks([0.30, 0.40]), source: .mic, sampleRate: 16_000)

        #expect(observedLayers.values() == [2, 2])
    }

    @Test
    func decoderStateCreationFailureFallsBackToFreshState() async throws {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setDecoderStateFactoryForTesting { _ in
            throw TestError.decoderStateCreationFailed
        }

        let observedLayers = DecoderStateProbe()
        await service.setAsrTranscribeHookForTesting { _, _, state in
            observedLayers.record(layerCount: decoderLayerCount(in: state))
            return ASRResult(text: "hello", confidence: 1.0, duration: 0.1, processingTime: 0.01)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)

        #expect(observedLayers.values() == [2])
    }

    // MARK: - Confidence Gate Tests (task 3.2)

    @Test
    func lowConfidenceResultDiscardedWhenGateAboveZero() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.asrConfidenceGate = 0.30
        await service.setStoredConfigForTesting(config)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _, _ in
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
        await service.setAsrTranscribeHookForTesting { _, _, _ in
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
        await service.setAsrTranscribeHookForTesting { _, _, _ in
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

    // MARK: - Segment Sanitizer Tests

    @Test
    func punctuationOnlyResultEmitsNoSegment() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setStoredConfigForTesting(.defaults)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _, _ in
            ASRResult(text: ". ", confidence: 1.0, duration: 1.0, processingTime: 0.1)
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

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        #expect(receivedSegments.isEmpty)
        #expect(await service.lastFinalSegmentEndOffsetForTesting(source: .mic) == nil)
    }

    @Test
    func leadingPunctuationStrippedBeforeEmission() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setStoredConfigForTesting(.defaults)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _, _ in
            ASRResult(text: ". Yeah and then we should go", confidence: 1.0, duration: 1.0, processingTime: 0.1)
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

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()

        #expect(receivedSegments.count == 1)
        #expect(receivedSegments.first?.text == "Yeah and then we should go")
    }

    @Test
    func droppedSegmentKeepsPreviousEndOffset() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setStoredConfigForTesting(.defaults)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))

        let texts = TextSequenceProbe(["hello there", "."])
        await service.setAsrTranscribeHookForTesting { _, _, _ in
            ASRResult(text: texts.next(), confidence: 1.0, duration: 1.0, processingTime: 0.1)
        }

        let firstProcessor = MockVADProcessor()
        await firstProcessor.enqueue(triggered: true, event: .speechStart)
        await firstProcessor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(firstProcessor)
        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)

        let offsetAfterCleanSegment = await service.lastFinalSegmentEndOffsetForTesting(source: .mic)
        #expect(offsetAfterCleanSegment != nil)

        let secondProcessor = MockVADProcessor()
        await secondProcessor.enqueue(triggered: true, event: .speechStart)
        await secondProcessor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(secondProcessor)
        await service.process(samples: makeChunks([0.30, 0.40]), source: .mic, sampleRate: 16_000)

        #expect(await service.lastFinalSegmentEndOffsetForTesting(source: .mic) == offsetAfterCleanSegment)
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

    // MARK: - LS-EEND Turn Attribution (task 5.1)

    /// Timeline built from raw frame predictions (0.1s frames, pass-through
    /// thresholding) — the same structure a live LS-EEND session produces.
    private func makeTurnTimeline(frameSpeakers: [Int?], numSpeakers: Int) throws -> DiarizerTimeline {
        var predictions: [Float] = []
        for active in frameSpeakers {
            for speaker in 0..<numSpeakers {
                predictions.append(speaker == active ? 1.0 : 0.0)
            }
        }
        return try DiarizerTimeline(
            allPredictions: predictions,
            config: .default(numSpeakers: numSpeakers, frameDurationSeconds: 0.1)
        )
    }

    private func makeAttributionService(
        text: String,
        timeline: DiarizerTimeline?
    ) async -> LiveTranscriptionService {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setStoredConfigForTesting(.defaults)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { samples, _, _ in
            ASRResult(
                text: text,
                confidence: 1.0,
                duration: TimeInterval(samples.count) / 16_000,
                processingTime: 0.1
            )
        }

        let lseend = LSEENDDiarizer()
        if let timeline {
            lseend.timeline = timeline
        }
        await service.setLSEENDDiarizersForTesting([.mic: lseend])
        return service
    }

    private func collectSegments(
        from service: LiveTranscriptionService,
        samples: [Float],
        vadStates: [(Bool, LiveVADEventKind?)]
    ) async -> [TranscriptSegment] {
        let processor = MockVADProcessor()
        for (triggered, event) in vadStates {
            await processor.enqueue(triggered: triggered, event: event)
        }
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in await service.transcriptStream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: samples, source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        collectTask.cancel()
        return receivedSegments
    }

    @Test
    func emptyTimelineFallsBackToSingleEmbeddingAttributedSegment() async {
        let service = await makeAttributionService(text: "hello world", timeline: nil)

        let segments = await collectSegments(
            from: service,
            samples: Array(repeating: Float(0.1), count: 8192),
            vadStates: [(true, .speechStart), (false, .speechEnd)]
        )

        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "unknown")
        #expect(segments.first?.text == "hello world")
        #expect(segments.first?.startTime == 0)
    }

    @Test
    func speakerTurnInsideBufferSplitsSegmentsAtRunBoundary() async throws {
        // 26 frames of 0.1s: speaker 0 for 1.3s, then speaker 1 for 1.3s.
        let timeline = try makeTurnTimeline(
            frameSpeakers: Array(repeating: 0, count: 13) + Array(repeating: 1, count: 13),
            numSpeakers: 2
        )
        let service = await makeAttributionService(text: "one two three four", timeline: timeline)

        // 10 VAD chunks of 4096 samples => one flushed 2.56s buffer at offset 0.
        var vadStates: [(Bool, LiveVADEventKind?)] = [(true, .speechStart)]
        vadStates.append(contentsOf: Array(repeating: (true, nil), count: 8))
        vadStates.append((false, .speechEnd))

        let segments = await collectSegments(
            from: service,
            samples: Array(repeating: Float(0.1), count: 40_960),
            vadStates: vadStates
        )

        #expect(segments.count == 2)
        let first = try #require(segments.first)
        let second = try #require(segments.last)

        #expect(first.speakerId == "speaker_mic_0")
        #expect(first.text == "one two")
        #expect(abs(first.startTime - 0) < 0.01)
        #expect(abs(first.endTime - 1.3) < 0.05)

        #expect(second.speakerId == "speaker_mic_1")
        #expect(second.text == "three four")
        #expect(second.startTime == first.endTime)
        #expect(abs(second.endTime - 2.56) < 0.01)
    }

    @Test
    func subSecondInterjectionDoesNotSplitSegment() async throws {
        // Speaker 0 holds 2.1s; speaker 1 interjects for the final 0.5s only.
        let timeline = try makeTurnTimeline(
            frameSpeakers: Array(repeating: 0, count: 21) + Array(repeating: 1, count: 5),
            numSpeakers: 2
        )
        let service = await makeAttributionService(text: "one two three four", timeline: timeline)

        var vadStates: [(Bool, LiveVADEventKind?)] = [(true, .speechStart)]
        vadStates.append(contentsOf: Array(repeating: (true, nil), count: 8))
        vadStates.append((false, .speechEnd))

        let segments = await collectSegments(
            from: service,
            samples: Array(repeating: Float(0.1), count: 40_960),
            vadStates: vadStates
        )

        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "speaker_mic_0")
        #expect(segments.first?.text == "one two three four")
    }

    @Test
    func boundIdentityRecordLabelsSegmentsWithProfileName() async throws {
        let timeline = try makeTurnTimeline(
            frameSpeakers: Array(repeating: 0, count: 26),
            numSpeakers: 2
        )
        let service = await makeAttributionService(text: "hello there", timeline: timeline)

        var identity = SessionSpeakerIdentity()
        identity.boundProfileID = UUID()
        identity.boundProfileName = "Alice"
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity)

        var vadStates: [(Bool, LiveVADEventKind?)] = [(true, .speechStart)]
        vadStates.append(contentsOf: Array(repeating: (true, nil), count: 8))
        vadStates.append((false, .speechEnd))

        let segments = await collectSegments(
            from: service,
            samples: Array(repeating: Float(0.1), count: 40_960),
            vadStates: vadStates
        )

        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "Alice")
    }
}

@Suite
struct LiveSpeakerTimelineTests {
    /// 0.125s frames: exactly representable in Float, so times on the
    /// 0.125 grid survive the segment's frame quantization untouched.
    private func segment(_ speaker: Int, _ start: Float, _ end: Float) -> DiarizerSegment {
        DiarizerSegment(speakerIndex: speaker, startTime: start, endTime: end, frameDurationSeconds: 0.125)
    }

    @Test
    func speakerRunsClipsToRangeAndOrdersByTime() {
        let runs = LiveSpeakerTimeline.speakerRuns(
            in: [segment(1, 3.0, 6.0), segment(0, 0.0, 2.0)],
            start: 1.0,
            end: 5.0
        )
        #expect(runs == [
            SpeakerRun(speakerIndex: 0, start: 1.0, end: 2.0),
            SpeakerRun(speakerIndex: 1, start: 3.0, end: 5.0)
        ])
    }

    @Test
    func speakerRunsMergesSameSpeakerAcrossFrameGap() {
        let runs = LiveSpeakerTimeline.speakerRuns(
            in: [segment(0, 0.0, 1.0), segment(0, 1.125, 2.0)],
            start: 0.0,
            end: 2.0
        )
        #expect(runs == [SpeakerRun(speakerIndex: 0, start: 0.0, end: 2.0)])
    }

    @Test
    func speakerRunsIgnoresSegmentsOutsideRange() {
        let runs = LiveSpeakerTimeline.speakerRuns(
            in: [segment(0, 5.0, 6.0)],
            start: 0.0,
            end: 2.0
        )
        #expect(runs.isEmpty)
    }

    @Test
    func dominantSpeakerPicksLongestTotalOverlap() {
        let segments = [segment(0, 0.0, 1.0), segment(1, 1.0, 3.0), segment(0, 3.0, 3.5)]
        #expect(LiveSpeakerTimeline.dominantSpeaker(in: segments, start: 0.0, end: 3.5) == 1)
        #expect(LiveSpeakerTimeline.dominantSpeaker(in: [], start: 0.0, end: 3.5) == nil)
    }

    @Test
    func planPartsReturnsEmptyForEmptyRuns() {
        #expect(LiveSegmentSplitter.planParts(runs: [], start: 0.0, end: 2.0).isEmpty)
    }

    @Test
    func planPartsSingleSpeakerCoversWholeBuffer() {
        let parts = LiveSegmentSplitter.planParts(
            runs: [SpeakerRun(speakerIndex: 2, start: 0.5, end: 1.75)],
            start: 0.0,
            end: 2.0
        )
        #expect(parts == [SegmentPart(speakerIndex: 2, start: 0.0, end: 2.0)])
    }

    @Test
    func planPartsSplitsAtGapMidpointAndTilesBuffer() {
        let parts = LiveSegmentSplitter.planParts(
            runs: [
                SpeakerRun(speakerIndex: 0, start: 0.0, end: 1.25),
                SpeakerRun(speakerIndex: 1, start: 1.5, end: 3.0)
            ],
            start: 0.0,
            end: 3.0
        )
        #expect(parts == [
            SegmentPart(speakerIndex: 0, start: 0.0, end: 1.375),
            SegmentPart(speakerIndex: 1, start: 1.375, end: 3.0)
        ])
    }

    @Test
    func planPartsMergesSubSecondRunIntoDominant() {
        let parts = LiveSegmentSplitter.planParts(
            runs: [
                SpeakerRun(speakerIndex: 0, start: 0.0, end: 2.0),
                SpeakerRun(speakerIndex: 1, start: 2.0, end: 2.5)
            ],
            start: 0.0,
            end: 2.5
        )
        #expect(parts == [SegmentPart(speakerIndex: 0, start: 0.0, end: 2.5)])
    }

    @Test
    func planPartsCollapsesConsecutiveSameSpeakerRuns() {
        let parts = LiveSegmentSplitter.planParts(
            runs: [
                SpeakerRun(speakerIndex: 0, start: 0.0, end: 1.25),
                SpeakerRun(speakerIndex: 0, start: 1.5, end: 2.5),
                SpeakerRun(speakerIndex: 1, start: 2.5, end: 4.0)
            ],
            start: 0.0,
            end: 4.0
        )
        #expect(parts == [
            SegmentPart(speakerIndex: 0, start: 0.0, end: 2.5),
            SegmentPart(speakerIndex: 1, start: 2.5, end: 4.0)
        ])
    }

    @Test
    func apportionTextSplitsWordsProportionallyWithoutTimings() {
        let parts = [
            SegmentPart(speakerIndex: 0, start: 0.0, end: 2.0),
            SegmentPart(speakerIndex: 1, start: 2.0, end: 4.0)
        ]
        let texts = LiveSegmentSplitter.apportionText(
            "one two three four",
            parts: parts,
            bufferStart: 0.0,
            tokenTimings: nil
        )
        #expect(texts == ["one two", "three four"])
    }

    @Test
    func apportionTextUsesTokenTimingsWhenAvailable() {
        // Proportional split would put 3 words in the first part (boundary at
        // 75% of the buffer); token timings say only 2 tokens precede it.
        let parts = [
            SegmentPart(speakerIndex: 0, start: 0.0, end: 3.0),
            SegmentPart(speakerIndex: 1, start: 3.0, end: 4.0)
        ]
        let timings = [
            TokenTiming(token: "one", tokenId: 1, startTime: 0.0, endTime: 1.0, confidence: 1.0),
            TokenTiming(token: "two", tokenId: 2, startTime: 1.0, endTime: 2.0, confidence: 1.0),
            TokenTiming(token: "three", tokenId: 3, startTime: 3.1, endTime: 3.4, confidence: 1.0),
            TokenTiming(token: "four", tokenId: 4, startTime: 3.4, endTime: 3.9, confidence: 1.0)
        ]
        let texts = LiveSegmentSplitter.apportionText(
            "one two three four",
            parts: parts,
            bufferStart: 0.0,
            tokenTimings: timings
        )
        #expect(texts == ["one two", "three four"])
    }

    @Test
    func apportionTextSinglePartReturnsWholeText() {
        let parts = [SegmentPart(speakerIndex: 0, start: 0.0, end: 2.0)]
        #expect(
            LiveSegmentSplitter.apportionText("hello world", parts: parts, bufferStart: 0.0, tokenTimings: nil)
                == ["hello world"]
        )
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
    case decoderStateCreationFailed
}

private actor FlushProbe {
    private var calls = 0
    private var lastSampleCount: Int?
    private var lastSampleValues: [Float]?
    private var sampleValues: [[Float]] = []
    private var lastSourceValue: Scriberman.AudioSource?
    private var lastOffsetValue: Float?

    func recordCall(samples: [Float]? = nil, samplesCount: Int? = nil, source: Scriberman.AudioSource? = nil, offset: Float? = nil) {
        calls += 1
        if let samples {
            lastSampleValues = samples
            sampleValues.append(samples)
            lastSampleCount = samples.count
        }
        if let samplesCount {
            lastSampleCount = samplesCount
        }
        if let source {
            lastSourceValue = source
        }
        if let offset {
            lastOffsetValue = offset
        }
    }

    func callCount() -> Int { calls }
    func lastSamplesCount() -> Int? { lastSampleCount }
    func lastSamples() -> [Float]? { lastSampleValues }
    func allSamples() -> [[Float]] { sampleValues }
    func lastSource() -> Scriberman.AudioSource? { lastSourceValue }
    func lastOffset() -> Float? { lastOffsetValue }
}

private func makeChunks(_ values: [Float]) -> [Float] {
    values.flatMap { Array(repeating: $0, count: 4096) }
}

private struct DecoderStateSourceCall: Equatable {
    let source: Scriberman.AudioSource
    let layerCount: Int?
}

private final class TextSequenceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]

    init(_ texts: [String]) {
        self.texts = texts
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return texts.isEmpty ? "" : texts.removeFirst()
    }
}

private final class DecoderStateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var layerCounts: [Int?] = []

    func record(layerCount: Int?) {
        lock.lock()
        defer { lock.unlock() }
        layerCounts.append(layerCount)
    }

    func values() -> [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return layerCounts
    }
}

private final class DecoderStateBySourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [DecoderStateSourceCall] = []

    func record(source: Scriberman.AudioSource, layerCount: Int?) {
        lock.lock()
        defer { lock.unlock() }
        recordedCalls.append(DecoderStateSourceCall(source: source, layerCount: layerCount))
    }

    func calls() -> [DecoderStateSourceCall] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }
}

private func decoderLayerCount(in state: TdtDecoderState) -> Int? {
    let mirror = Mirror(reflecting: state)
    guard let hiddenState = mirror.children.first(where: { $0.label == "hiddenState" })?.value as? MLMultiArray,
          let firstDimension = hiddenState.shape.first
    else {
        return nil
    }
    return firstDimension.intValue
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
