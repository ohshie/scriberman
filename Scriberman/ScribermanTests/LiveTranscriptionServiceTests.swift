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

    /// A turn-speaker identity with `seconds` of speech.
    private func turnIdentity(_ embedding: [Float], seconds: Float = 3) -> SessionSpeakerIdentity {
        var identity = SessionSpeakerIdentity()
        identity.accumulate(embedding, seconds: seconds)
        return identity
    }

    @Test
    func stopEnrollsNoUnmatchedSpeaker() async throws {
        let store = try makeStore()
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: turnIdentity(Array(repeating: 0.1, count: 256)))
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 1, identity: turnIdentity(Array(repeating: -0.1, count: 256)))

        _ = await service.stop()

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test
    func stopLeavesExistingProfilesUntouched() async throws {
        let store = try makeStore()
        let speaker3Embedding = Array(repeating: Float(0.3), count: 256)
        let speaker3 = try await store.enrollNamedSpeaker(name: "Speaker 3", embedding: speaker3Embedding)
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        var unrelated = Array(repeating: Float(0), count: 256)
        unrelated[0] = 1
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: turnIdentity(unrelated))

        _ = await service.stop()

        #expect(try await store.fetchAllSnapshots().map(\.name) == ["Speaker 3"])
        #expect(try await store.findProfileSnapshot(byID: speaker3)?.embedding == speaker3Embedding)
    }

    @Test
    func stopUpdatesLastSeenForMatchedSpeaker() async throws {
        let store = try makeStore()
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let aliceEmbedding = Array(repeating: Float(0.1), count: 256)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: aliceEmbedding)
        let aliceID = try #require(try await store.fetchAllSnapshots().first { $0.name == "Alice" }?.id)
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: turnIdentity(aliceEmbedding))

        _ = await service.stop()

        let profiles = try await store.fetchAllSnapshots()
        #expect(profiles.map(\.name) == ["Alice"])
        let updated = try #require(try await store.findProfileSnapshot(byID: aliceID))
        #expect(updated.lastSeen > oldDate)
    }

    @Test
    func stopWithoutStoreDoesNotCrash() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)

        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: turnIdentity(Array(repeating: 0.5, count: 256)))

        let result = await service.stop()
        #expect(result.speakerEmbeddings.keys.sorted() == ["speaker_mic_0"])
    }

    @Test
    func micAudioSourceMapsToMicrophoneASRSource() {
        let domainMic = AudioSource.mic
        let domainApp = AudioSource.app

        #expect(domainMic != domainApp)
        #expect(domainMic.rawValue == "mic")
        #expect(domainApp.rawValue == "app")
    }

    private func makeWorkspace() -> Workspace {
        Workspace(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func settings(vadThreshold: Double) -> LiveTranscriptionPipelineSettings {
        var config = LiveTranscriptionPipelineSettings.defaults
        config.vadThreshold = vadThreshold
        return config
    }

    @Test
    func prepareKeepsServiceUninitializedWhenVADInitializationFails() async throws {
        let loads = FakeModelLoads()
        loads.vadFailuresRemaining = 1
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil, modelLoader: loads.loader)

        await service.prepare(workspace: makeWorkspace())

        #expect(await service.isInitialized == false)
    }

    @Test
    func missingVoiceprintModelKeepsServiceUninitializedAndStartThrows() async {
        let loads = FakeModelLoads()
        loads.voiceprintFailuresRemaining = 2
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil, modelLoader: loads.loader)
        let workspace = makeWorkspace()

        await service.prepare(workspace: workspace)
        #expect(await service.isInitialized == false)

        let (_, continuation) = AsyncStream<TranscriptSegment>.makeStream()
        await #expect(throws: LiveTranscriptionError.initializationFailed) {
            try await service.start(workspace: workspace, resultContinuation: continuation)
        }
        #expect(await service.isInitialized == false)
        #expect(loads.voiceprintLoadCount == 2)
    }

    @Test
    func prepareForAnotherProcessorLoadsAgainAndTheSameProcessorReusesModels() async {
        let loads = FakeModelLoads()
        let processor = LiveProcessorBox(.gpu)
        let service = LiveTranscriptionService(
            speakerEmbeddingStore: nil,
            modelLoader: loads.loader,
            processor: { processor.value }
        )
        let workspace = makeWorkspace()

        await service.prepare(workspace: workspace)
        await service.prepare(workspace: workspace)
        #expect(loads.asrLoadCount == 1)

        processor.value = .neuralEngine
        await service.prepare(workspace: workspace)
        #expect(loads.asrLoadCount == 2)
        #expect(loads.asrProcessors == [.gpu, .neuralEngine])
    }

    @Test
    func concurrentPrepareAndStartLoadModelsOnce() async throws {
        let gate = LoadGate()
        let loads = FakeModelLoads(gate: gate)
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil, modelLoader: loads.loader)
        let workspace = makeWorkspace()

        let warmup = Task { await service.prepare(workspace: workspace) }
        #expect(await loads.waitForAsrLoads(1))
        let (_, continuation) = AsyncStream<TranscriptSegment>.makeStream()
        let start = Task { try await service.start(workspace: workspace, resultContinuation: continuation) }
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        await warmup.value
        try await start.value

        #expect(loads.asrLoadCount == 1)
        #expect(loads.vadThresholds.count == 1)
        #expect(await service.isInitialized)
    }

    @Test
    func startRetriesPreparationAfterFailedWarmup() async throws {
        let loads = FakeModelLoads()
        loads.asrFailuresRemaining = 1
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil, modelLoader: loads.loader)
        let workspace = makeWorkspace()

        await service.prepare(workspace: workspace)
        #expect(await service.isInitialized == false)

        let (_, continuation) = AsyncStream<TranscriptSegment>.makeStream()
        try await service.start(workspace: workspace, resultContinuation: continuation)

        #expect(loads.asrLoadCount == 2)
        #expect(await service.isInitialized)
    }

    @Test
    func vadThresholdChangedAfterWarmupIsUsedByTheRecording() async throws {
        let loads = FakeModelLoads()
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil, modelLoader: loads.loader)
        let workspace = makeWorkspace()

        await service.prepare(workspace: workspace, config: settings(vadThreshold: 0.5))
        let (_, continuation) = AsyncStream<TranscriptSegment>.makeStream()
        try await service.start(workspace: workspace, config: settings(vadThreshold: 0.7), resultContinuation: continuation)
        await service.process(samples: Array(repeating: 0.1, count: 4_096), source: .mic, sampleRate: 16_000)

        #expect(loads.vadThresholds == [0.5, 0.7])
        #expect(loads.processedThresholds == [0.7])
    }

    @Test
    func consecutiveRecordingsStartFromCleanState() async throws {
        let loads = FakeModelLoads()
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil, modelLoader: loads.loader)
        let workspace = makeWorkspace()
        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { samples, source, offset in
            await flushProbe.recordCall(samplesCount: samples.count, source: source, offset: offset)
        }

        let (_, first) = AsyncStream<TranscriptSegment>.makeStream()
        try await service.start(workspace: workspace, resultContinuation: first)
        await service.process(samples: Array(repeating: 0.9, count: 10_000), source: .mic, sampleRate: 16_000)
        _ = await service.stop()
        #expect(await flushProbe.lastOffset() == 0)
        #expect(await flushProbe.lastSamplesCount() == 10_000)

        let (_, second) = AsyncStream<TranscriptSegment>.makeStream()
        try await service.start(workspace: workspace, resultContinuation: second)
        await service.process(samples: Array(repeating: 0.9, count: 5_000), source: .mic, sampleRate: 16_000)
        _ = await service.stop()

        #expect(await flushProbe.callCount() == 2)
        #expect(await flushProbe.lastOffset() == 0)
        #expect(await flushProbe.lastSamplesCount() == 5_000)
        #expect(loads.turnDiarizers.map(\.samples.count) == [10_000, 5_000])
        #expect(loads.voiceprintLoadCount == 2)
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
    func speechOffsetCountsFromSampleZeroWhenCallsLeaveARemainder() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { samples, source, offset in
            await flushProbe.recordCall(samplesCount: samples.count, source: source, offset: offset)
        }

        await service.process(samples: Array(repeating: 0.1, count: 5_000), source: .mic, sampleRate: 16_000)
        await service.process(samples: Array(repeating: 0.1, count: 3_192), source: .mic, sampleRate: 16_000)

        #expect(await flushProbe.callCount() == 1)
        #expect(await flushProbe.lastSamplesCount() == 8_192)
        #expect(await flushProbe.lastOffset() == 0)
    }

    @Test
    func chunkedAndUnchunkedInputProduceEqualSegmentTimes() async {
        let audio = [Float](repeating: 0, count: 10_000)
            + [Float](repeating: 0.9, count: 30_000)
            + [Float](repeating: 0, count: 20_000)
            + [Float](repeating: 0.9, count: 12_000)
            + [Float](repeating: 0, count: 16_000)

        func segmentTimes(callLengths: [Int]) async -> [SegmentTimes] {
            let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
            await service.setVADProcessorForTesting(AmplitudeVAD())
            let probe = SegmentTimesProbe()
            await service.setProcessChunkHookForTesting { samples, _, offset in
                probe.record(SegmentTimes(start: offset, end: offset + Float(samples.count) / 16_000))
            }
            var position = 0
            var lengths = callLengths[...]
            while position < audio.count {
                let length = min(lengths.popFirst() ?? audio.count, audio.count - position)
                await service.process(samples: Array(audio[position..<(position + length)]), source: .mic, sampleRate: 16_000)
                position += length
            }
            _ = await service.stop()
            return probe.values()
        }

        let unchunked = await segmentTimes(callLengths: [audio.count])
        let chunked = await segmentTimes(callLengths: [5_000, 3_192, 1_024, 7_777, 480, 12_000, 333] + Array(repeating: 2_048, count: 40))

        #expect(unchunked.count == 2)
        #expect(chunked == unchunked)
    }

    @Test
    func stopFeedsVoicedRemainderIntoTheFinalSegment() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        await service.setVADProcessorForTesting(AmplitudeVAD())

        let flushProbe = FlushProbe()
        await service.setProcessChunkHookForTesting { samples, source, offset in
            await flushProbe.recordCall(samples: samples, source: source, offset: offset)
        }

        await service.process(samples: Array(repeating: 0.9, count: 4_096), source: .mic, sampleRate: 16_000)
        await service.process(samples: Array(repeating: 0.8, count: 3_000), source: .mic, sampleRate: 16_000)
        #expect(await flushProbe.callCount() == 0)

        _ = await service.stop()

        let flushed = await flushProbe.lastSamples()
        #expect(await flushProbe.callCount() == 1)
        #expect(flushed?.count == 7_096)
        #expect(flushed?.suffix(3_000).allSatisfy { $0 == 0.8 } == true)
        #expect(await flushProbe.lastOffset() == 0)
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
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
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
            for await segment in results.stream {
                receivedSegments.append(segment)
                if receivedSegments.count == 2 {
                    break
                }
            }
        }

        await service.process(samples: makeChunks([0.10, 0.11, 0.20, 0.30, 0.31]), source: .mic, sampleRate: 16_000)
        // Every segment is yielded before process returns; finishing lets the collector drain them.
        results.continuation.finish()
        await collectTask.value

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
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
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
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        let loudSamples = Array(repeating: Float(0.1), count: 8192)
        await service.process(samples: loudSamples, source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.isEmpty)
    }

    @Test
    func confidenceGateDisabledPassesAllResults() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
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
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        let loudSamples = Array(repeating: Float(0.1), count: 8192)
        await service.process(samples: loudSamples, source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.count == 1)
    }

    @Test
    func highConfidenceResultAboveGatePasses() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
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
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        let loudSamples = Array(repeating: Float(0.1), count: 8192)
        await service.process(samples: loudSamples, source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.count == 1)
    }

    // MARK: - Segment Sanitizer Tests

    @Test
    func punctuationOnlyResultEmitsNoSegment() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
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
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.isEmpty)
        #expect(await service.lastFinalSegmentEndOffsetForTesting(source: .mic) == nil)
    }

    @Test
    func leadingPunctuationStrippedBeforeEmission() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
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
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

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

    // MARK: - Cleanup Rules Tests

    @Test
    func cleanupRuleRemovesWordFromEmittedSegment() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.cleanupRules = [TranscriptCleanupRule(pattern: "huh", position: .anywhere, wholeWord: true)]
        await service.setStoredConfigForTesting(config)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _, _ in
            ASRResult(text: "That's it, huh.", confidence: 1.0, duration: 1.0, processingTime: 0.1)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.count == 1)
        #expect(receivedSegments.first?.text == "That's it.")
    }

    @Test
    func cleanupRuleDropsSingleWordSegment() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.cleanupRules = [TranscriptCleanupRule(pattern: "huh", position: .anywhere, wholeWord: true)]
        await service.setStoredConfigForTesting(config)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _, _ in
            ASRResult(text: "huh", confidence: 1.0, duration: 1.0, processingTime: 0.1)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.isEmpty)
        #expect(await service.lastFinalSegmentEndOffsetForTesting(source: .mic) == nil)
    }

    @Test
    func cleanupRulesRunAfterBuiltInSanitizer() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
        var config = LiveTranscriptionPipelineSettings.defaults
        config.cleanupRules = [TranscriptCleanupRule(pattern: "huh", position: .anywhere, wholeWord: true)]
        await service.setStoredConfigForTesting(config)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _, _ in
            ASRResult(text: ". huh", confidence: 1.0, duration: 1.0, processingTime: 0.1)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.isEmpty)
    }

    @Test
    func emptyCleanupRulesLeaveEmissionUnchanged() async {
        let service = LiveTranscriptionService(speakerEmbeddingStore: nil)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
        await service.setStoredConfigForTesting(.defaults)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        await service.setAsrTranscribeHookForTesting { _, _, _ in
            ASRResult(text: "huh, that's fine", confidence: 1.0, duration: 1.0, processingTime: 0.1)
        }

        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: makeChunks([0.10, 0.20]), source: .mic, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value

        #expect(receivedSegments.count == 1)
        #expect(receivedSegments.first?.text == "huh, that's fine")
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
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
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

    // MARK: - Turn Attribution

    /// One committed chunk from frame speakers given at 0.1s resolution,
    /// expanded to the diarizer's 10ms frames (one-hot probabilities).
    private func makeTurnTimeline(frameSpeakers: [Int?], numSpeakers: Int) throws -> TurnDiarizerChunk {
        var probabilities: [Float] = []
        for active in frameSpeakers {
            for _ in 0..<10 {
                for speaker in 0..<numSpeakers {
                    probabilities.append(speaker == active ? 1.0 : 0.0)
                }
            }
        }
        return TurnDiarizerChunk(probabilities: probabilities, frameCount: frameSpeakers.count * 10)
    }

    /// `timeline` is committed on the first feed; nil commits 10s of silence,
    /// so the buffer is covered but has no speaker activity.
    private func makeAttributionService(
        text: String,
        timeline: TurnDiarizerChunk?,
        store: SpeakerEmbeddingStore? = nil
    ) async -> LiveTranscriptionService {
        await makeAttributionService(texts: [text], timeline: timeline, store: store)
    }

    private func makeAttributionService(
        texts: [String],
        timeline: TurnDiarizerChunk?,
        store: SpeakerEmbeddingStore? = nil
    ) async -> LiveTranscriptionService {
        let chunk = timeline ?? TurnDiarizerChunk(probabilities: Array(repeating: 0, count: 1000 * 2), frameCount: 1000)
        let diarizer = ScriptedTurnDiarizer(numSpeakers: 2, feedResponses: [.success([chunk])])
        return await makeAttributionService(texts: texts, diarizer: diarizer, store: store)
    }

    private func makeAttributionService(
        texts: [String],
        diarizer: ScriptedTurnDiarizer,
        store: SpeakerEmbeddingStore? = nil
    ) async -> LiveTranscriptionService {
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
        await service.setStoredConfigForTesting(.defaults)
        await service.setAsrManagerForTesting(AsrManager(config: ASRConfig()))
        let textProbe = TextSequenceProbe(texts)
        await service.setAsrTranscribeHookForTesting { samples, _, _ in
            ASRResult(
                text: textProbe.next(),
                confidence: 1.0,
                duration: TimeInterval(samples.count) / 16_000,
                processingTime: 0.1
            )
        }
        await service.setTurnDiarizersForTesting([.mic: diarizer])
        return service
    }

    private func collectSegments(
        from service: LiveTranscriptionService,
        samples: [Float],
        vadStates: [(Bool, LiveVADEventKind?)],
        source: Scriberman.AudioSource = .mic
    ) async -> [TranscriptSegment] {
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
        let processor = MockVADProcessor()
        for (triggered, event) in vadStates {
            await processor.enqueue(triggered: triggered, event: event)
        }
        await service.setVADProcessorForTesting(processor)

        var receivedSegments: [TranscriptSegment] = []
        let collectTask = Task {
            for await segment in results.stream {
                receivedSegments.append(segment)
            }
        }

        await service.process(samples: samples, source: source, sampleRate: 16_000)
        results.continuation.finish()
        await collectTask.value
        return receivedSegments
    }

    /// Collects every segment the service yields until cancelled.
    private func startCollecting(from service: LiveTranscriptionService) async -> (task: Task<Void, Never>, box: SegmentBox) {
        let results = AsyncStream<TranscriptSegment>.makeStream()
        await service.setResultContinuationForTesting(results.continuation)
        let box = SegmentBox()
        let task = Task {
            for await segment in results.stream {
                await box.append(segment)
            }
        }
        return (task, box)
    }

    @Test
    func bufferIsHeldUntilTurnTimelineCoversIt() async throws {
        let covering = try makeTurnTimeline(frameSpeakers: Array(repeating: 0, count: 10), numSpeakers: 2)
        let diarizer = ScriptedTurnDiarizer(numSpeakers: 2, feedResponses: [.success([]), .success([covering])])
        let service = await makeAttributionService(texts: ["hello there"], diarizer: diarizer)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)
        let (task, box) = await startCollecting(from: service)
        defer { task.cancel() }

        await service.process(samples: Array(repeating: Float(0.1), count: 8192), source: .mic, sampleRate: 16_000)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await box.values().isEmpty)
        #expect(await service.pendingAttributionCountForTesting(source: .mic) == 1)

        await service.process(samples: Array(repeating: Float(0), count: 4096), source: .mic, sampleRate: 16_000)
        let segments = await box.values(atLeast: 1)
        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "speaker_mic_0")
        #expect(await service.pendingAttributionCountForTesting(source: .mic) == 0)
    }

    @Test
    func heldBuffersAreEmittedInOrder() async throws {
        let covering = try makeTurnTimeline(frameSpeakers: Array(repeating: 0, count: 20), numSpeakers: 2)
        let diarizer = ScriptedTurnDiarizer(numSpeakers: 2, feedResponses: [.success([]), .success([covering])])
        let service = await makeAttributionService(texts: ["first", "second"], diarizer: diarizer)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)
        let (task, box) = await startCollecting(from: service)
        defer { task.cancel() }

        await service.process(samples: Array(repeating: Float(0.1), count: 16_384), source: .mic, sampleRate: 16_000)
        #expect(await service.pendingAttributionCountForTesting(source: .mic) == 2)

        await service.process(samples: Array(repeating: Float(0), count: 4096), source: .mic, sampleRate: 16_000)
        #expect(await box.values(atLeast: 2).map(\.text) == ["first", "second"])
    }

    @Test
    func heldBufferIsReleasedAtStop() async throws {
        let covering = try makeTurnTimeline(frameSpeakers: Array(repeating: 1, count: 10), numSpeakers: 2)
        let diarizer = ScriptedTurnDiarizer(numSpeakers: 2, feedResponses: [], finishResponse: [covering])
        let service = await makeAttributionService(texts: ["hello there"], diarizer: diarizer)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)

        await service.process(samples: Array(repeating: Float(0.1), count: 8192), source: .mic, sampleRate: 16_000)
        #expect(await service.pendingAttributionCountForTesting(source: .mic) == 1)

        let segments = await service.stop().segments
        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "speaker_mic_1")
    }

    /// Spec scenario "Held buffer released on diarizer failure".
    @Test
    func heldBufferGoesToTheUnknownSpeakerWhenTurnDiarizerFails() async {
        let diarizer = ScriptedTurnDiarizer(
            numSpeakers: 2,
            feedResponses: [.success([]), .failure(TestError.turnDiarizerFailed)]
        )
        let service = await makeAttributionService(texts: ["hello there"], diarizer: diarizer)
        let processor = MockVADProcessor()
        await processor.enqueue(triggered: true, event: .speechStart)
        await processor.enqueue(triggered: false, event: .speechEnd)
        await service.setVADProcessorForTesting(processor)
        let (task, box) = await startCollecting(from: service)
        defer { task.cancel() }

        await service.process(samples: Array(repeating: Float(0.1), count: 8192), source: .mic, sampleRate: 16_000)
        #expect(await service.pendingAttributionCountForTesting(source: .mic) == 1)

        await service.process(samples: Array(repeating: Float(0), count: 4096), source: .mic, sampleRate: 16_000)
        let segments = await box.values(atLeast: 1)
        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "speaker_mic_unknown")
    }

    /// Spec scenario "Timeline has no speaker activity for the range".
    @Test
    func emptyTimelineGoesToTheUnknownSpeaker() async {
        let service = await makeAttributionService(text: "hello world", timeline: nil)

        let segments = await collectSegments(
            from: service,
            samples: Array(repeating: Float(0.1), count: 8192),
            vadStates: oneSpeechChunkPair
        )

        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "speaker_mic_unknown")
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

    private func vadChunks(_ count: Int) -> [(Bool, LiveVADEventKind?)] {
        [(true, .speechStart)] + Array(repeating: (true, nil), count: count - 2) + [(false, .speechEnd)]
    }

    /// Runs one speech buffer of `vadChunkCount` × 4096 samples starting at offset 0 through a
    /// service whose turn timeline is `timeline` and whose voiceprint model is `embedder`.
    private func attributeOneBuffer(
        timeline: TurnDiarizerChunk,
        vadChunkCount: Int,
        embedder: FakeEmbedder
    ) async -> (service: LiveTranscriptionService, segments: [TranscriptSegment]) {
        let service = await makeAttributionService(text: "one two three four", timeline: timeline)
        await service.setVoiceprintEmbedderForTesting { try embedder.embed($0, $1) }
        let segments = await collectSegments(
            from: service,
            samples: Array(repeating: Float(0.1), count: vadChunkCount * 4096),
            vadStates: vadChunks(vadChunkCount)
        )
        return (service, segments)
    }

    /// As above, with the timeline given as speakers at 0.1s resolution.
    private func attributeOneBuffer(
        frameSpeakers: [Int?],
        vadChunkCount: Int,
        embedder: FakeEmbedder
    ) async throws -> (service: LiveTranscriptionService, segments: [TranscriptSegment]) {
        let timeline = try makeTurnTimeline(frameSpeakers: frameSpeakers, numSpeakers: 2)
        return await attributeOneBuffer(timeline: timeline, vadChunkCount: vadChunkCount, embedder: embedder)
    }

    /// Frames of a 100-frame mask that are set.
    private func activeFrames(_ mask: [Float]) -> [Int] {
        mask.indices.filter { mask[$0] != 0 }
    }

    /// Spec scenario "Short run gives no voiceprint".
    @Test
    func shortRunGivesNoVoiceprint() async throws {
        // Speaker 0 for 2.0s, speaker 1 for 0.6s; the buffer ends at 2.816s.
        let embedder = FakeEmbedder([voice(0)])
        let (service, _) = try await attributeOneBuffer(
            frameSpeakers: Array(repeating: 0, count: 20) + Array(repeating: 1, count: 6) + Array(repeating: nil, count: 3),
            vadChunkCount: 11,
            embedder: embedder
        )

        #expect(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 1) == nil)
        let zero = try #require(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 0))
        #expect(abs(zero.speechSeconds - 2.0) < 0.01)
    }

    /// Spec scenario "Short runs separated by a small gap": the gap merge used for splitting does
    /// not reach the voiceprints.
    @Test
    func shortRunsSeparatedByASmallGapGiveNoVoiceprint() async throws {
        // Speaker 0 at 0–0.6s and 0.7–1.3s; the buffer ends at 1.536s.
        let embedder = FakeEmbedder([voice(0)])
        let (service, segments) = try await attributeOneBuffer(
            frameSpeakers: Array(repeating: 0, count: 6) + [nil] + Array(repeating: 0, count: 6) + Array(repeating: nil, count: 3),
            vadChunkCount: 6,
            embedder: embedder
        )

        #expect(segments.map(\.speakerId) == ["speaker_mic_0"])
        #expect(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 0) == nil)
        #expect(embedder.calls.isEmpty)
    }

    /// Spec scenario "Overlapped speech is excluded".
    @Test
    func overlappedSpeechIsExcludedFromVoiceprints() async throws {
        // A 0–4s, B 3–6s at 10ms frames; the buffer ends at 6.144s.
        var probabilities: [Float] = []
        for frame in 0..<620 {
            probabilities.append(frame < 400 ? 1 : 0)
            probabilities.append(frame >= 300 && frame < 600 ? 1 : 0)
        }
        let embedder = FakeEmbedder([voice(0)])
        let (service, _) = await attributeOneBuffer(
            timeline: TurnDiarizerChunk(probabilities: probabilities, frameCount: 620),
            vadChunkCount: 24,
            embedder: embedder
        )

        let masks = try #require(embedder.calls.first)
        #expect(embedder.calls.count == 1)
        #expect(masks.map(activeFrames) == [Array(0..<30), Array(40..<60)])
        let a = try #require(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 0))
        let b = try #require(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 1))
        #expect(abs(a.speechSeconds - 3.0) < 0.01)
        #expect(abs(b.speechSeconds - 2.0) < 0.01)
    }

    /// Spec scenario "Absorbed short turn keeps its own voiceprint".
    @Test
    func absorbedShortTurnKeepsItsOwnVoiceprint() async throws {
        // A 0–0.8s, B 0.8–2.0s, A 2.0–2.8s: only B's run reaches 1s, so the whole buffer is one
        // part for A.
        let embedder = FakeEmbedder([voice(1)])
        let (service, segments) = try await attributeOneBuffer(
            frameSpeakers: Array(repeating: 0, count: 8) + Array(repeating: 1, count: 12)
                + Array(repeating: 0, count: 8) + Array(repeating: nil, count: 2),
            vadChunkCount: 11,
            embedder: embedder
        )

        #expect(segments.map(\.speakerId) == ["speaker_mic_0"])
        let b = try #require(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 1))
        #expect(abs(b.speechSeconds - 1.2) < 0.01)
        #expect(b.averagedEmbedding == voice(1))
        #expect(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 0) == nil)
    }

    @Test
    func voiceprintRangesAreBufferRelativeAndUnmerged() {
        let ranges = LiveSpeakerTimeline.voiceprintRanges(
            in: [
                TurnSegment(speakerIndex: 0, start: 9.0, end: 11.0),
                TurnSegment(speakerIndex: 1, start: 11.5, end: 12.5),
                TurnSegment(speakerIndex: 0, start: 12.6, end: 20.0),
                TurnSegment(speakerIndex: 1, start: 20.0, end: 21.0)
            ],
            start: 10.0,
            end: 13.0
        )

        #expect(ranges.map(\.speaker) == ["0", "1", "0"])
        let expected: [(Double, Double)] = [(0.0, 1.0), (1.5, 2.5), (2.6, 3.0)]
        for (range, bounds) in zip(ranges, expected) {
            #expect(abs(range.start - bounds.0) < 0.001)
            #expect(abs(range.end - bounds.1) < 0.001)
        }
    }

    /// A unit vector along `axis`; distinct axes are orthogonal voices.
    private func voice(_ axis: Int) -> [Float] {
        (0..<256).map { $0 == axis ? Float(1) : Float(0) }
    }

    private let oneSpeechChunkPair: [(Bool, LiveVADEventKind?)] = [(true, .speechStart), (false, .speechEnd)]

    private let tenVADChunks: [(Bool, LiveVADEventKind?)] =
        [(true, .speechStart)] + Array(repeating: (true, nil), count: 8) + [(false, .speechEnd)]

    /// An identity with `seconds` of speech whose voiceprint is `embedding`.
    private func identity(_ embedding: [Float], seconds: Float = 3, boundTo profile: (UUID, String)? = nil) -> SessionSpeakerIdentity {
        var identity = SessionSpeakerIdentity()
        identity.accumulate(embedding, seconds: seconds)
        identity.boundProfileID = profile?.0
        identity.boundProfileName = profile?.1
        return identity
    }

    /// Spec scenarios "Known speaker recognized mid-session", "Short speech is not matched" and
    /// "Earlier segments relabelled at stop".
    @Test
    func stopRelabelsTurnSpeakerSegmentsEmittedBeforeTheMatch() async throws {
        let store = try makeStore()
        try await store.enrollNamedSpeaker(name: "Alice", embedding: voice(0))
        // Speaker 0 throughout both 2.56s buffers, so 2.56s of qualifying speech in each.
        let timeline = try makeTurnTimeline(frameSpeakers: Array(repeating: 0, count: 60), numSpeakers: 2)
        let service = await makeAttributionService(texts: ["before the match", "after the match"], timeline: timeline, store: store)
        let embedder = FakeEmbedder([voice(0)])
        await service.setVoiceprintEmbedderForTesting { try embedder.embed($0, $1) }

        let before = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        let after = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)

        #expect(before.map(\.speakerId) == ["speaker_mic_0"])
        #expect(after.map(\.speakerId) == ["Alice"])

        let result = await service.stop()
        #expect(result.segments.map(\.speakerId) == ["Alice", "Alice"])
        #expect(result.segments.map(\.id) == (before + after).map(\.id))
        #expect(result.finalSpeakerIDs == [before[0].id: "Alice", after[0].id: "Alice"])
        #expect(try await store.fetchAllSnapshots().count == 1)
    }

    /// Spec scenario "Profile reassigned between speakers": index 0 is shown as Bob, loses the
    /// match, and index 1 ends with it. Relabelling by segment keeps them apart.
    @Test
    func profileReassignedBetweenSpeakersRelabelsBySegment() async throws {
        let store = try makeStore()
        let bobID = try await store.enrollNamedSpeaker(name: "Bob", embedding: voice(1))
        // Speaker 0 for the first buffer, speaker 1 for the second.
        let timeline = try makeTurnTimeline(frameSpeakers: Array(repeating: 0, count: 26) + Array(repeating: 1, count: 26), numSpeakers: 2)
        let service = await makeAttributionService(texts: ["zero speaks", "one speaks"], timeline: timeline, store: store)
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity(voice(1), boundTo: (bobID, "Bob")))

        let first = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        // Index 0's voiceprint has since moved away from Bob; index 1 sounds like Bob.
        var moved = identity(voice(1), boundTo: (bobID, "Bob"))
        moved.accumulate(voice(2), seconds: 30)
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: moved)
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 1, identity: identity(voice(1)))
        let second = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)

        #expect(first.map(\.speakerId) == ["Bob"])
        #expect(second.map(\.speakerId) == ["speaker_mic_1"])

        let result = await service.stop()
        #expect(result.segments.map(\.speakerId) == ["speaker_mic_0", "Bob"])
        #expect(result.finalSpeakerIDs == [first[0].id: "speaker_mic_0", second[0].id: "Bob"])
    }

    /// Spec scenario "Match lost before stop".
    @Test
    func matchLostBeforeStopFallsBackToTheSessionLocalID() async throws {
        let store = try makeStore()
        let bobID = try await store.enrollNamedSpeaker(name: "Bob", embedding: voice(1))
        let timeline = try makeTurnTimeline(frameSpeakers: Array(repeating: 1, count: 30), numSpeakers: 2)
        let service = await makeAttributionService(text: "shown as bob", timeline: timeline, store: store)
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 1, identity: identity(voice(3), boundTo: (bobID, "Bob")))

        let segments = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        let result = await service.stop()

        #expect(segments.map(\.speakerId) == ["Bob"])
        #expect(result.segments.map(\.speakerId) == ["speaker_mic_1"])
        #expect(result.speakerEmbeddings == ["speaker_mic_1": voice(3)])
    }

    @Test
    func deletingAllProfilesMidRecordingKeepsLabelsUntilStopAndCreatesNothing() async throws {
        let store = try makeStore()
        let aliceID = try await store.enrollNamedSpeaker(name: "Alice", embedding: voice(0))
        let timeline = try makeTurnTimeline(frameSpeakers: Array(repeating: 0, count: 30), numSpeakers: 2)
        let service = await makeAttributionService(text: "after deletion", timeline: timeline, store: store)
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity(voice(0), boundTo: (aliceID, "Alice")))
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 1, identity: identity(voice(1)))

        try await store.deleteAllProfiles()
        let segments = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        let result = await service.stop()

        #expect(segments.map(\.speakerId) == ["Alice"])
        #expect(result.segments.map(\.speakerId) == ["speaker_mic_0"])
        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    /// Spec scenario "Speech accumulates across short buffers", with the second buffer starting
    /// at a nonzero session offset.
    @Test
    func speechAccumulatesAcrossShortBuffers() async throws {
        let store = try makeStore()
        try await store.enrollNamedSpeaker(name: "Alice", embedding: voice(0))
        // Speaker 0 at 0–1.6s and 2.1–3.7s; buffers 0–2.048s and 2.048–4.096s. 1.6s per buffer
        // keeps each below 3s alone.
        let timeline = try makeTurnTimeline(
            frameSpeakers: Array(repeating: 0, count: 16) + Array(repeating: nil, count: 5)
                + Array(repeating: 0, count: 16) + Array(repeating: nil, count: 4),
            numSpeakers: 2
        )
        let service = await makeAttributionService(texts: ["first", "second"], timeline: timeline, store: store)
        let embedder = FakeEmbedder([voice(0)])
        await service.setVoiceprintEmbedderForTesting { try embedder.embed($0, $1) }

        let first = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 8 * 4096), vadStates: vadChunks(8))
        let afterFirst = try #require(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 0))
        #expect(abs(afterFirst.speechSeconds - 1.6) < 0.01)
        let second = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 8 * 4096), vadStates: vadChunks(8))

        #expect(first.map(\.speakerId) == ["speaker_mic_0"])
        #expect(second.map(\.speakerId) == ["Alice"])
        let afterSecond = try #require(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 0))
        #expect(abs(afterSecond.speechSeconds - 3.2) < 0.01)
        // The second buffer starts at 2.048s: speech at 2.1–3.7s is 0.052–1.652s into it.
        let secondMasks = try #require(embedder.calls.last)
        #expect(secondMasks.map(activeFrames) == [Array(1...16)])
    }

    /// Spec scenario "Early wrong match is corrected".
    @Test
    func earlyWrongMatchIsCorrectedAndRelabelledAtStop() async throws {
        let store = try makeStore()
        try await store.enrollNamedSpeaker(name: "Alice", embedding: voice(0))
        try await store.enrollNamedSpeaker(name: "Bob", embedding: voice(1))
        let timeline = try makeTurnTimeline(frameSpeakers: Array(repeating: 0, count: 130), numSpeakers: 2)
        let service = await makeAttributionService(texts: ["one", "two", "three", "four", "five"], timeline: timeline, store: store)
        // Two buffers sound like Bob, then the voice settles on Alice.
        let embedder = FakeEmbedder([voice(1), voice(1), voice(0)])
        await service.setVoiceprintEmbedderForTesting { try embedder.embed($0, $1) }

        var emitted: [TranscriptSegment] = []
        for _ in 0..<5 {
            emitted += await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        }
        let result = await service.stop()

        #expect(emitted.map(\.speakerId) == ["speaker_mic_0", "Bob", "Bob", "speaker_mic_0", "Alice"])
        #expect(result.segments.map(\.speakerId) == Array(repeating: "Alice", count: 5))
        #expect(result.finalSpeakerIDs == Dictionary(uniqueKeysWithValues: emitted.map { ($0.id, "Alice") }))
    }

    /// Spec scenario "Voiceprint extraction fails": the model throws.
    @Test
    func throwingVoiceprintModelStillEmitsEveryBuffer() async throws {
        try await expectBuffersEmittedWithoutVoiceprints(embedder: FakeEmbedder([voice(0)], error: TestError.embeddingFailed))
    }

    /// Spec scenario "Voiceprint extraction fails": the model returns no usable vector.
    @Test
    func unusableVoiceprintStillEmitsEveryBuffer() async throws {
        try await expectBuffersEmittedWithoutVoiceprints(embedder: FakeEmbedder([Array(repeating: 0, count: 256)]))
    }

    private func expectBuffersEmittedWithoutVoiceprints(embedder: FakeEmbedder) async throws {
        let timeline = try makeTurnTimeline(frameSpeakers: Array(repeating: 0, count: 60), numSpeakers: 2)
        let service = await makeAttributionService(texts: ["first", "second"], timeline: timeline)
        await service.setVoiceprintEmbedderForTesting { try embedder.embed($0, $1) }

        let first = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        let second = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)

        #expect(first.map(\.text) == ["first"])
        #expect(second.map(\.text) == ["second"])
        #expect((first + second).map(\.speakerId) == ["speaker_mic_0", "speaker_mic_0"])
        #expect(embedder.calls.count == 2)
        #expect(await service.speakerIdentityForTesting(source: .mic, speakerIndex: 0) == nil)
    }

    /// Spec scenario "Turn diarizer failed".
    @Test
    func turnDiarizerFailureSendsLaterBuffersToTheUnknownSpeaker() async throws {
        let store = try makeStore()
        try await store.enrollNamedSpeaker(name: "Alice", embedding: voice(0))
        let diarizer = ScriptedTurnDiarizer(numSpeakers: 2, feedResponses: [.failure(TestError.turnDiarizerFailed)])
        let service = await makeAttributionService(texts: ["first", "second"], diarizer: diarizer, store: store)
        let embedder = FakeEmbedder([voice(0)])
        await service.setVoiceprintEmbedderForTesting { try embedder.embed($0, $1) }

        let first = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        let second = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 40_960), vadStates: tenVADChunks)
        let result = await service.stop()

        #expect((first + second).map(\.speakerId) == ["speaker_mic_unknown", "speaker_mic_unknown"])
        #expect(result.segments.map(\.speakerId) == ["speaker_mic_unknown", "speaker_mic_unknown"])
        #expect(result.finalSpeakerIDs.isEmpty)
        #expect(result.speakerEmbeddings.isEmpty)
        #expect(embedder.calls.isEmpty)
    }

    /// Spec scenario "Sources keep separate unknown speakers".
    @Test
    func sourcesKeepSeparateUnknownSpeakers() async throws {
        let service = await makeAttributionService(texts: ["mic words", "app words"], timeline: nil)

        let mic = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 8192), vadStates: oneSpeechChunkPair)
        let app = await collectSegments(from: service, samples: Array(repeating: Float(0.1), count: 8192), vadStates: oneSpeechChunkPair, source: .app)

        #expect(mic.map(\.speakerId) == ["speaker_mic_unknown"])
        #expect(app.map(\.speakerId) == ["speaker_app_unknown"])
    }

    @Test
    func speakerIDsNeverCollide() {
        let ids = [
            LiveSpeakerReference.turn(.mic, 0).sessionLocalID,
            LiveSpeakerReference.turn(.app, 0).sessionLocalID,
            LiveSpeakerReference.turn(.mic, 1).sessionLocalID,
            LiveSpeakerReference.unknownSpeakerID(for: .mic),
            LiveSpeakerReference.unknownSpeakerID(for: .app)
        ]
        #expect(Set(ids).count == ids.count)
    }

    @Test
    func stopLogsOneLinePerIdentity() async throws {
        let store = try makeStore()
        let aliceID = try await store.enrollNamedSpeaker(name: "Alice", embedding: voice(0))
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)
        let lines = LogLines()
        await service.setNoticeLogSinkForTesting { lines.append($0) }
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity(voice(0), seconds: 4))
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 1, identity: identity(voice(1), seconds: 2))

        _ = await service.stop()

        #expect(lines.values == [
            "🗣 Speaker speaker_mic_0: 4.0s qualifying speech, voiceprint saved: yes, profile: \(aliceID.uuidString)",
            "🗣 Speaker speaker_mic_1: 2.0s qualifying speech, voiceprint saved: no, profile: none"
        ])
    }

    @Test
    func stopReportsVoiceprintsPerFinalSpeakerIDAndEnrollsNothing() async throws {
        let store = try makeStore()
        try await store.enrollNamedSpeaker(name: "Alice", embedding: voice(0))
        try await store.enrollNamedSpeaker(name: "Carol", embedding: voice(2))
        let service = LiveTranscriptionService(speakerEmbeddingStore: store)

        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 0, identity: identity(voice(0)))
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 1, identity: identity(voice(1)))
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 2, identity: identity(voice(2)))
        await service.injectSpeakerIdentityForTesting(source: .mic, speakerIndex: 3, identity: identity(voice(3), seconds: 1))

        let result = await service.stop()

        #expect(result.speakerEmbeddings == [
            "Alice": voice(0),
            "speaker_mic_1": voice(1),
            "Carol": voice(2)
        ])
        #expect(Set(try await store.fetchAllSnapshots().map(\.name)) == ["Alice", "Carol"])
    }
}

@Suite
struct LiveSpeakerTimelineTests {
    private func segment(_ speaker: Int, _ start: Float, _ end: Float) -> TurnSegment {
        TurnSegment(speakerIndex: speaker, start: start, end: end)
    }

    /// Frame-major one-hot probabilities, 0.125s frames (exact in Float).
    private func probabilities(_ frameSpeakers: [Int?], numSpeakers: Int = 2) -> [Float] {
        frameSpeakers.flatMap { active in
            (0..<numSpeakers).map { $0 == active ? Float(1) : Float(0) }
        }
    }

    @Test
    func turnTimelineCoverageFollowsCommittedFrames() {
        var timeline = TurnTimeline(numSpeakers: 2, frameSeconds: 0.125)
        #expect(timeline.coveredUntil == 0)
        timeline.append(probabilities: probabilities([0, 0, nil, nil]), frameCount: 4)
        #expect(timeline.coveredUntil == 0.5)
    }

    @Test
    func turnTimelineJoinsRunAcrossChunks() {
        var timeline = TurnTimeline(numSpeakers: 2, frameSeconds: 0.125)
        timeline.append(probabilities: probabilities([0, 0]), frameCount: 2)
        timeline.append(probabilities: probabilities([0, 0, 1, 1, 1, 1]), frameCount: 6)
        #expect(timeline.segments == [segment(0, 0.0, 0.5), segment(1, 0.5, 1.0)])
    }

    @Test
    func turnTimelineDropsRunsShorterThanMinimum() {
        var timeline = TurnTimeline(numSpeakers: 2, frameSeconds: 0.125)
        timeline.append(probabilities: probabilities([0, nil, 1, 1, nil]), frameCount: 5)
        #expect(timeline.segments == [segment(1, 0.25, 0.5)])
    }

    @Test
    func turnTimelineIncludesRunOpenAtCommittedEdge() {
        var timeline = TurnTimeline(numSpeakers: 2, frameSeconds: 0.125)
        timeline.append(probabilities: probabilities([nil, 1, 1, 1]), frameCount: 4)
        #expect(timeline.segments == [segment(1, 0.125, 0.5)])
    }

    @Test
    func turnTimelineTracksEightSpeakers() {
        var timeline = TurnTimeline(numSpeakers: 8, frameSeconds: 0.125)
        timeline.append(probabilities: probabilities([7, 7, 7, 3, 3, 3], numSpeakers: 8), frameCount: 6)
        #expect(timeline.segments == [segment(7, 0.0, 0.375), segment(3, 0.375, 0.75)])
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
            TokenTiming(token: " one", tokenId: 1, startTime: 0.0, endTime: 1.0, confidence: 1.0),
            TokenTiming(token: " two", tokenId: 2, startTime: 1.0, endTime: 2.0, confidence: 1.0),
            TokenTiming(token: " three", tokenId: 3, startTime: 3.1, endTime: 3.4, confidence: 1.0),
            TokenTiming(token: " four", tokenId: 4, startTime: 3.4, endTime: 3.9, confidence: 1.0)
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

    @Test
    func apportionTextKeepsMultiTokenWordWhole() {
        // FluidAudio replaces SentencePiece's word-boundary marker with a leading
        // space, so " un" opens a word and "bel", "iev", "able" continue it.
        let parts = [
            SegmentPart(speakerIndex: 0, start: 0.0, end: 1.5),
            SegmentPart(speakerIndex: 1, start: 1.5, end: 2.5)
        ]
        let timings = [
            TokenTiming(token: " un", tokenId: 1, startTime: 0.2, endTime: 0.4, confidence: 1.0),
            TokenTiming(token: "bel", tokenId: 2, startTime: 0.4, endTime: 0.6, confidence: 1.0),
            TokenTiming(token: "iev", tokenId: 3, startTime: 0.6, endTime: 0.8, confidence: 1.0),
            TokenTiming(token: "able", tokenId: 4, startTime: 0.8, endTime: 1.0, confidence: 1.0),
            TokenTiming(token: " yes", tokenId: 5, startTime: 1.8, endTime: 2.0, confidence: 1.0)
        ]
        let texts = LiveSegmentSplitter.apportionText(
            "unbelievable yes",
            parts: parts,
            bufferStart: 0.0,
            tokenTimings: timings
        )
        #expect(texts == ["unbelievable", "yes"])
    }

    @Test
    func planPartsTilesBufferForRandomOverlappingRuns() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<500 {
            let bufferEnd = Float.random(in: 2...20, using: &generator)
            let runs = (0..<Int.random(in: 2...6, using: &generator)).map { _ in
                let runStart = Float.random(in: 0..<bufferEnd, using: &generator)
                return SpeakerRun(
                    speakerIndex: Int.random(in: 0..<4, using: &generator),
                    start: runStart,
                    end: min(bufferEnd, runStart + Float.random(in: 0.2...8, using: &generator))
                )
            }
            let parts = LiveSegmentSplitter.planParts(runs: runs, start: 0.0, end: bufferEnd)

            #expect(!parts.isEmpty)
            #expect(parts.first?.start == 0.0)
            #expect(parts.last?.end == bufferEnd)
            #expect(parts.allSatisfy { $0.end >= $0.start })
            #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.end == $1.start })
        }
    }

    @Test
    func apportionTextSplitsByDurationWhenTimingsMissing() {
        let parts = [
            SegmentPart(speakerIndex: 0, start: 0.0, end: 3.0),
            SegmentPart(speakerIndex: 1, start: 3.0, end: 4.0)
        ]
        let texts = LiveSegmentSplitter.apportionText(
            "a b c d e f g h",
            parts: parts,
            bufferStart: 0.0,
            tokenTimings: []
        )
        #expect(texts == ["a b c d e f", "g h"])
    }

    @Test
    func apportionTextStitchesPunctuatedSentenceLikeASRText() {
        let parts = [
            SegmentPart(speakerIndex: 0, start: 10.0, end: 13.0),
            SegmentPart(speakerIndex: 1, start: 13.0, end: 14.0)
        ]
        let timings = [
            TokenTiming(token: " Hel", tokenId: 1, startTime: 0.1, endTime: 0.3, confidence: 1.0),
            TokenTiming(token: "lo", tokenId: 2, startTime: 0.3, endTime: 0.5, confidence: 1.0),
            TokenTiming(token: ",", tokenId: 3, startTime: 0.5, endTime: 0.6, confidence: 1.0),
            TokenTiming(token: " how", tokenId: 4, startTime: 0.8, endTime: 1.0, confidence: 1.0),
            TokenTiming(token: " are", tokenId: 5, startTime: 1.0, endTime: 1.2, confidence: 1.0),
            TokenTiming(token: " you", tokenId: 6, startTime: 1.2, endTime: 1.5, confidence: 1.0),
            TokenTiming(token: "?", tokenId: 7, startTime: 1.5, endTime: 1.6, confidence: 1.0)
        ]
        let texts = LiveSegmentSplitter.apportionText(
            "Hello, how are you?",
            parts: parts,
            bufferStart: 10.0,
            tokenTimings: timings
        )
        #expect(texts == ["Hello, how are you?", ""])
    }

    @Test
    func planPartsResolvesOverlappingRunsWithoutInvertedParts() {
        let parts = LiveSegmentSplitter.planParts(
            runs: [
                SpeakerRun(speakerIndex: 0, start: 0.0, end: 10.0),
                SpeakerRun(speakerIndex: 1, start: 1.0, end: 3.0),
                SpeakerRun(speakerIndex: 2, start: 4.0, end: 6.0)
            ],
            start: 0.0,
            end: 10.0
        )
        #expect(parts == [
            SegmentPart(speakerIndex: 0, start: 0.0, end: 1.0),
            SegmentPart(speakerIndex: 1, start: 1.0, end: 3.0),
            SegmentPart(speakerIndex: 0, start: 3.0, end: 4.0),
            SegmentPart(speakerIndex: 2, start: 4.0, end: 6.0),
            SegmentPart(speakerIndex: 0, start: 6.0, end: 10.0)
        ])
    }

    @Test
    func speakerRunsMergesSameSpeakerAcrossInterleavedRun() {
        let runs = LiveSpeakerTimeline.speakerRuns(
            in: [segment(0, 0.0, 2.0), segment(1, 1.5, 3.0), segment(0, 2.1, 4.0)],
            start: 0.0,
            end: 4.0
        )
        #expect(runs == [
            SpeakerRun(speakerIndex: 0, start: 0.0, end: 4.0),
            SpeakerRun(speakerIndex: 1, start: 1.5, end: 3.0)
        ])
    }
}

private enum TestError: Error {
    case modelLoadFailed
    case vadInitializationFailed
    case decoderStateCreationFailed
    case turnDiarizerFailed
    case embeddingFailed
}

/// Turn diarizer that commits scripted chunks: one `feedResponses` entry per
/// feed call (nothing once they run out), `finishResponse` on finish.
private final class ScriptedTurnDiarizer: StreamingTurnDiarizing, @unchecked Sendable {
    let numSpeakers: Int
    let frameSeconds: Float = 0.01
    private let lock = NSLock()
    private var feedResponses: [Result<[TurnDiarizerChunk], TestError>]
    private let finishResponse: [TurnDiarizerChunk]

    init(
        numSpeakers: Int,
        feedResponses: [Result<[TurnDiarizerChunk], TestError>],
        finishResponse: [TurnDiarizerChunk] = []
    ) {
        self.numSpeakers = numSpeakers
        self.feedResponses = feedResponses
        self.finishResponse = finishResponse
    }

    func feed(_ samples: [Float]) throws -> [TurnDiarizerChunk] {
        lock.lock()
        defer { lock.unlock() }
        guard !feedResponses.isEmpty else { return [] }
        return try feedResponses.removeFirst().get()
    }

    func finish() throws -> [TurnDiarizerChunk] { finishResponse }

    func reset() {}
}

private actor SegmentBox {
    private var segments: [TranscriptSegment] = []
    func append(_ segment: TranscriptSegment) { segments.append(segment) }
    func values() -> [TranscriptSegment] { segments }

    /// Segments once at least `count` have arrived, or whatever arrived by the timeout.
    func values(atLeast count: Int, timeout: Duration = .seconds(5)) async -> [TranscriptSegment] {
        let deadline = ContinuousClock.now + timeout
        while segments.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return segments
    }
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

/// Voiceprint model that returns one scripted vector per call for every mask (the last vector
/// repeats), or throws `error`. Records each call's masks.
private final class FakeEmbedder: @unchecked Sendable {
    private let lock = NSLock()
    private var vectors: [[Float]]
    private let error: TestError?
    private var recorded: [[[Float]]] = []

    init(_ vectors: [[Float]], error: TestError? = nil) {
        self.vectors = vectors
        self.error = error
    }

    var calls: [[[Float]]] { lock.withLock { recorded } }

    func embed(_ window: ArraySlice<Float>, _ masks: [[Float]]) throws -> [[Float]] {
        let vector: [Float] = lock.withLock {
            recorded.append(masks)
            return vectors.count > 1 ? vectors.removeFirst() : vectors[0]
        }
        if let error { throw error }
        return masks.map { _ in vector }
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var values: [String] { lock.withLock { lines } }

    func append(_ line: String) {
        lock.withLock { lines.append(line) }
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

private actor LoadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Model loader that counts loads, optionally fails, and records the VAD
/// threshold of each load and of each processed chunk.
private final class LiveProcessorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AsrProcessor

    init(_ value: AsrProcessor) {
        stored = value
    }

    var value: AsrProcessor {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class FakeModelLoads: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: LoadGate?
    private var asrLoads = 0
    private var thresholds: [Double] = []
    private var processed: [Double] = []
    private var diarizers: [SampleRecordingDiarizer] = []
    private var voiceprintLoads = 0
    private var voiceprintFailures = 0
    private var asrFailures = 0
    private var vadFailures = 0

    init(gate: LoadGate? = nil) {
        self.gate = gate
    }

    var asrFailuresRemaining: Int {
        get { locked { asrFailures } }
        set { locked { asrFailures = newValue } }
    }
    var vadFailuresRemaining: Int {
        get { locked { vadFailures } }
        set { locked { vadFailures = newValue } }
    }
    var voiceprintFailuresRemaining: Int {
        get { locked { voiceprintFailures } }
        set { locked { voiceprintFailures = newValue } }
    }
    var asrLoadCount: Int { locked { asrLoads } }
    private var loadedProcessors: [AsrProcessor] = []
    var asrProcessors: [AsrProcessor] { locked { loadedProcessors } }
    var vadThresholds: [Double] { locked { thresholds } }
    var processedThresholds: [Double] { locked { processed } }
    var turnDiarizers: [SampleRecordingDiarizer] { locked { diarizers } }
    var voiceprintLoadCount: Int { locked { voiceprintLoads } }

    func waitForAsrLoads(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while asrLoadCount < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return asrLoadCount >= count
    }

    func recordProcessed(threshold: Double) {
        locked { processed.append(threshold) }
    }

    var loader: LiveModelLoader {
        LiveModelLoader(
            loadAsr: { _, processor in
                let shouldFail = self.locked {
                    self.asrLoads += 1
                    self.loadedProcessors.append(processor)
                    guard self.asrFailures > 0 else { return false }
                    self.asrFailures -= 1
                    return true
                }
                await self.gate?.wait()
                if shouldFail { throw TestError.modelLoadFailed }
                return AsrManager(config: ASRConfig())
            },
            loadVoiceprintExtractor: { _ in
                let shouldFail = self.locked {
                    self.voiceprintLoads += 1
                    guard self.voiceprintFailures > 0 else { return false }
                    self.voiceprintFailures -= 1
                    return true
                }
                if shouldFail { throw LiveTranscriptionError.initializationFailed }
                return LiveVoiceprintExtractor(SpeakerVoiceprintExtractor(maskFrameCount: 100) { _, masks in
                    masks.map { _ in [1] }
                })
            },
            loadVad: { _, construction in
                let shouldFail = self.locked {
                    guard self.vadFailures > 0 else { return false }
                    self.vadFailures -= 1
                    return true
                }
                if shouldFail { throw TestError.vadInitializationFailed }
                self.locked { self.thresholds.append(construction.vadThreshold) }
                return ThresholdRecordingVAD(threshold: construction.vadThreshold, loads: self)
            },
            loadTurnDiarizers: { _ in
                return {
                    let diarizer = SampleRecordingDiarizer()
                    self.locked { self.diarizers.append(diarizer) }
                    return [.mic: diarizer]
                }
            }
        )
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Triggered while the chunk's peak is above 0.5, with a start event on the
/// transition. Records its construction threshold on every chunk.
private actor ThresholdRecordingVAD: LiveVADStreamingProcessing {
    let threshold: Double
    let loads: FakeModelLoads
    private var triggered = false

    init(threshold: Double, loads: FakeModelLoads) {
        self.threshold = threshold
        self.loads = loads
    }

    func processStreamingChunk(
        _ chunk: [Float],
        state: VadStreamState,
        config: VadSegmentationConfig
    ) async throws -> LiveVADProcessingResult {
        loads.recordProcessed(threshold: threshold)
        let voiced = (chunk.map { abs($0) }.max() ?? 0) > 0.5
        let event: LiveVADEventKind? = voiced && !triggered ? .speechStart : nil
        triggered = voiced
        return LiveVADProcessingResult(state: state, isTriggered: voiced, eventKind: event)
    }
}

/// VAD that decides from the chunk's content only: triggered while the peak is
/// above 0.5, with start and end events on each transition.
private actor AmplitudeVAD: LiveVADStreamingProcessing {
    private var triggered = false

    func processStreamingChunk(
        _ chunk: [Float],
        state: VadStreamState,
        config: VadSegmentationConfig
    ) async throws -> LiveVADProcessingResult {
        let voiced = (chunk.map { abs($0) }.max() ?? 0) > 0.5
        let event: LiveVADEventKind? = voiced == triggered ? nil : (voiced ? .speechStart : .speechEnd)
        triggered = voiced
        return LiveVADProcessingResult(state: state, isTriggered: voiced, eventKind: event)
    }
}

private struct SegmentTimes: Equatable {
    let start: Float
    let end: Float
}

private final class SegmentTimesProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [SegmentTimes] = []

    func record(_ value: SegmentTimes) {
        lock.lock()
        defer { lock.unlock() }
        times.append(value)
    }

    func values() -> [SegmentTimes] {
        lock.lock()
        defer { lock.unlock() }
        return times
    }
}

@MainActor
struct LiveRecordingSessionTests {
    @Test
    func endingSessionFinishesBothStreamsAndConsumers() async {
        let session = LiveRecordingSession()
        var audioEnded = false
        var resultsEnded = false
        session.audioConsumer = Task {
            for await _ in session.audio.stream {}
            audioEnded = true
        }
        session.resultConsumer = Task {
            for await _ in session.results.stream {}
            resultsEnded = true
        }
        session.finish()
        await session.drainAudio()
        await session.drainResults()
        #expect(audioEnded && resultsEnded)
        #expect(session.audioConsumer == nil && session.resultConsumer == nil)
    }

    @Test
    func slowConsumerReportsOncePerSourceAndRecoversWithoutDroppingAudio() async {
        let session = LiveRecordingSession()
        var events: [String] = []
        var count = 0
        let now = HostNanoseconds(nanoseconds: 30_000_000_000)
        session.audioConsumer = Task {
            var monitor = LiveAudioQueueMonitor { source, delayed, _ in
                events.append("\(source.rawValue):\(delayed)")
            }
            for await chunk in session.audio.stream {
                monitor.observe(chunk, now: now)
                try? await Task.sleep(for: .milliseconds(2))
                count += 1
            }
        }
        for source in [AudioSource.mic, .app] {
            for second: UInt64 in [15, 16, 29, 30] {
                session.audio.continuation.yield(LiveAudioChunk(samples: [1], source: source, sampleRate: 16_000, hostTime: HostNanoseconds(nanoseconds: second * 1_000_000_000)))
            }
        }
        session.finish()
        await session.drainAudio()
        #expect(count == 8)
        #expect(events == ["mic:true", "mic:false", "app:true", "app:false"])
    }
}

struct LiveCaptureTimingTests {
    @Test
    func lateAppAndOutageFeedSilenceToDiarizationAndVAD() async {
        let service = LiveTranscriptionService()
        let diarizer = SampleRecordingDiarizer()
        let vad = SampleRecordingVAD()
        await service.setTurnDiarizersForTesting([.app: diarizer])
        await service.setVADProcessorForTesting(vad)
        await service.process(samples: [1], source: .mic, sampleRate: 16_000, hostTime: HostNanoseconds(nanoseconds: 1_000_000_000))
        await service.process(samples: Array(repeating: 1, count: 16_000), source: .app, sampleRate: 16_000, hostTime: HostNanoseconds(nanoseconds: 4_000_000_000))
        #expect(await service.processedSampleCountForTesting(source: .app) == 64_000)
        await service.process(samples: Array(repeating: 2, count: 16_000), source: .app, sampleRate: 16_000, hostTime: HostNanoseconds(nanoseconds: 7_000_000_000))
        let expected = Array(repeating: Float(0), count: 48_000) + Array(repeating: Float(1), count: 16_000)
            + Array(repeating: Float(0), count: 32_000) + Array(repeating: Float(2), count: 16_000)
        #expect(diarizer.samples == expected)
        #expect(await vad.samples == Array(expected.prefix(expected.count / 4_096 * 4_096)))
        #expect(await service.processedSampleCountForTesting(source: .app) == 112_000)
    }

    @Test
    func absentHostTimeContinuesFromPriorPosition() async {
        let service = LiveTranscriptionService()
        await service.process(samples: Array(repeating: 1, count: 16_000), source: .mic, sampleRate: 16_000, hostTime: HostNanoseconds(nanoseconds: 1_000_000_000))
        await service.process(samples: Array(repeating: 1, count: 16_000), source: .mic, sampleRate: 16_000)
        #expect(await service.processedSampleCountForTesting(source: .mic) == 32_000)
    }
}

private final class SampleRecordingDiarizer: StreamingTurnDiarizing, @unchecked Sendable {
    let numSpeakers = 1
    let frameSeconds: Float = 0.01
    private(set) var samples: [Float] = []
    func feed(_ samples: [Float]) throws -> [TurnDiarizerChunk] { self.samples += samples; return [] }
    func finish() throws -> [TurnDiarizerChunk] { [] }
    func reset() { samples = [] }
}

private actor SampleRecordingVAD: LiveVADStreamingProcessing {
    private(set) var samples: [Float] = []
    func processStreamingChunk(_ chunk: [Float], state: VadStreamState, config: VadSegmentationConfig) async throws -> LiveVADProcessingResult {
        samples += chunk
        return LiveVADProcessingResult(state: state, isTriggered: false, eventKind: nil)
    }
}

extension LiveCaptureTimingTests {
    @Test
    func sharedCaptureAnchorDoesNotDependOnConsumerOrder() async {
        let clock = LiveCaptureClock()
        clock.observe(HostNanoseconds(nanoseconds: 4_000_000_000))
        clock.observe(HostNanoseconds(nanoseconds: 1_000_000_000))
        let service = LiveTranscriptionService()
        let chunk = LiveAudioChunk(samples: Array(repeating: 1, count: 16_000), source: .app, sampleRate: 16_000, hostTime: HostNanoseconds(nanoseconds: 4_000_000_000))
        await service.process(chunk, anchor: clock.anchor)
        #expect(await service.processedSampleCountForTesting(source: .app) == 64_000)
    }
}

extension LiveRecordingSessionTests {
    @Test
    func emptyQueueReportsRecoveryAtStop() {
        var events: [Bool] = []
        var monitor = LiveAudioQueueMonitor { _, delayed, _ in events.append(delayed) }
        monitor.observe(LiveAudioChunk(samples: [1], source: .mic, sampleRate: 16_000, hostTime: HostNanoseconds(nanoseconds: 0)), now: HostNanoseconds(nanoseconds: 15_000_000_000))
        monitor.finish()
        monitor.finish()
        #expect(events == [true, false])
    }
}

/// Deterministic generator so randomized tests reproduce (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
