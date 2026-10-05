import FluidAudio
import Foundation
import SwiftData
import Testing
import os
@testable import Scriberman

struct TranscriptionPassRunnerTests {
    @Test
    func runReturnsEmptyWhenVADProducesNoSpeech() async throws {
        let engineCreated = OSAllocatedUnfairLock(initialState: false)
        let runner = TranscriptionPassRunner(
            segmentSpeech: { _ in [] },
            makePassEngines: { _ in
                engineCreated.withLock { $0 = true }
                return TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "", tokenTimings: [])
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(segments: [], speakerDatabase: nil)
                    }
                )
            }
        )

        let workspace = try makeWorkspace()
        let passResult = try await runner.run(samples: [0, 0, 0], source: .mic, workspace: workspace)
        let segments = passResult.segments
        let embeddings = passResult.speakerEmbeddings

        #expect(segments.isEmpty)
        #expect(embeddings.isEmpty)
        #expect(!engineCreated.withLock { $0 })
    }

    @Test
    func sharedPassEnginesLoadsFactoryExactlyOnceAcrossConcurrentPasses() async throws {
        let factoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = TranscriptionService(
            segmentSpeech: { _ in [VadSegment(startTime: 0, endTime: 1)] },
            makePassEngines: { _ in
                factoryCalls.withLock { $0 += 1 }
                return TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "hello", tokenTimings: [])
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(segments: [], speakerDatabase: nil)
                    }
                )
            }
        )

        let workspace = try makeWorkspace()
        let samples = Array(repeating: Float(0.1), count: 16_000)
        let sharedEngines = await service.makeSharedPassEngines()

        async let mic = service.transcribePassFromSamples(
            samples: samples, source: .mic, workspace: workspace, engines: sharedEngines
        )
        async let app = service.transcribePassFromSamples(
            samples: samples, source: .app, workspace: workspace, engines: sharedEngines
        )
        _ = try await (mic, app)

        #expect(factoryCalls.withLock { $0 } == 1)
    }

    @Test
    func passesWithoutSharedEnginesLoadIndependently() async throws {
        let factoryCalls = OSAllocatedUnfairLock(initialState: 0)
        let service = TranscriptionService(
            segmentSpeech: { _ in [VadSegment(startTime: 0, endTime: 1)] },
            makePassEngines: { _ in
                factoryCalls.withLock { $0 += 1 }
                return TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "hello", tokenTimings: [])
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(segments: [], speakerDatabase: nil)
                    }
                )
            }
        )

        let workspace = try makeWorkspace()
        let samples = Array(repeating: Float(0.1), count: 16_000)

        _ = try await service.transcribePassFromSamples(samples: samples, source: .mic, workspace: workspace)
        _ = try await service.transcribePassFromSamples(samples: samples, source: .mic, workspace: workspace)

        #expect(factoryCalls.withLock { $0 } == 2)
    }

    @Test
    func runPrefixesAppSpeakerIDsInSegmentsAndEmbeddings() async throws {
        let diarizedSegments = [
            TimedSpeakerSegment(
                speakerId: "cluster_1",
                embedding: [],
                startTimeSeconds: 0,
                endTimeSeconds: 1,
                qualityScore: 1
            )
        ]

        let runner = TranscriptionPassRunner(
            segmentSpeech: { _ in
                [TranscriptionPassRunner.SpeechSegment(startTime: 0, endTime: 1)]
            },
            makePassEngines: { _ in
                TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "hello", tokenTimings: [])
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(
                            segments: diarizedSegments,
                            speakerDatabase: nil
                        )
                    },
                    extractVoiceprints: { _, _ in
                        ["cluster_1": SpeakerVoiceprintExtractor.Voiceprint(embedding: [0.2, 0.8], speechSeconds: 5)]
                    }
                )
            },
            alignTranscript: { _, _, _, _ in
                Transcript(
                    fullText: "hello",
                    segments: [
                        TranscriptSegment(
                            speakerId: "cluster_1",
                            text: "hello",
                            startTime: 0,
                            endTime: 1,
                            audioSource: .app
                        )
                    ],
                    speakers: []
                )
            }
        )

        let workspace = try makeWorkspace()
        let passResult = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .app, workspace: workspace)
        let segments = passResult.segments
        let embeddings = passResult.speakerEmbeddings

        #expect(segments.count == 1)
        #expect(segments[0].speakerId == "app:cluster_1")
        #expect(embeddings["app:cluster_1"] != nil)
    }

    @Test
    func runAppliesSpeakerMappingFromStore() async throws {
        let modelContainer = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = SpeakerEmbeddingStore(modelContainer: modelContainer)

        let embedding = normalizedEmbedding(length: 192, activeIndex: 0)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: embedding)

        let runner = TranscriptionPassRunner(
            speakerEmbeddingStore: store,
            segmentSpeech: { _ in
                [TranscriptionPassRunner.SpeechSegment(startTime: 0, endTime: 1)]
            },
            makePassEngines: { _ in
                TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "hello", tokenTimings: [])
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(
                            segments: [
                                TimedSpeakerSegment(
                                    speakerId: "cluster_1",
                                    embedding: [],
                                    startTimeSeconds: 0,
                                    endTimeSeconds: 1,
                                    qualityScore: 1
                                )
                            ],
                            speakerDatabase: nil
                        )
                    },
                    extractVoiceprints: { _, _ in
                        ["cluster_1": SpeakerVoiceprintExtractor.Voiceprint(embedding: embedding, speechSeconds: 5)]
                    }
                )
            },
            alignTranscript: { _, _, _, _ in
                Transcript(
                    fullText: "hello",
                    segments: [
                        TranscriptSegment(
                            speakerId: "cluster_1",
                            text: "hello",
                            startTime: 0,
                            endTime: 1,
                            audioSource: .mic
                        )
                    ],
                    speakers: []
                )
            }
        )

        let workspace = try makeWorkspace()
        let passResult = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .mic, workspace: workspace)
        let segments = passResult.segments
        let embeddings = passResult.speakerEmbeddings

        #expect(segments.count == 1)
        #expect(segments[0].speakerId == "Alice")
        #expect(embeddings["Alice"] != nil)
    }

    /// A runner whose diarizer returns `clusters` (id, start, end) and whose aligner emits one
    /// segment per cluster, with voiceprints from `voiceprints`.
    private func clusterRunner(
        store: SpeakerEmbeddingStore,
        clusters: [(id: String, start: Float, end: Float)],
        voiceprints: [String: [Float]],
        capturedRanges: RangeRecorder? = nil
    ) -> TranscriptionPassRunner {
        TranscriptionPassRunner(
            speakerEmbeddingStore: store,
            segmentSpeech: { _ in
                [TranscriptionPassRunner.SpeechSegment(startTime: 0, endTime: 1)]
            },
            makePassEngines: { _ in
                TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "hello", tokenTimings: [])
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(
                            segments: clusters.map {
                                TimedSpeakerSegment(
                                    speakerId: $0.id, embedding: [], startTimeSeconds: $0.start,
                                    endTimeSeconds: $0.end, qualityScore: 1
                                )
                            },
                            speakerDatabase: nil
                        )
                    },
                    extractVoiceprints: { _, ranges in
                        capturedRanges?.record(ranges)
                        return voiceprints.mapValues {
                            SpeakerVoiceprintExtractor.Voiceprint(embedding: $0, speechSeconds: 5)
                        }
                    }
                )
            },
            alignTranscript: { _, _, _, _ in
                Transcript(
                    fullText: "hello",
                    segments: clusters.map {
                        TranscriptSegment(speakerId: $0.id, text: "hello", startTime: $0.start, endTime: $0.end, audioSource: .mic)
                    },
                    speakers: []
                )
            }
        )
    }

    /// A cluster with too little single-speaker speech gets no voiceprint from the extractor, so it
    /// is neither matched nor stored.
    @Test
    func clusterWithoutVoiceprintStaysUnmatched() async throws {
        let modelContainer = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = SpeakerEmbeddingStore(modelContainer: modelContainer)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: normalizedEmbedding(length: 8, activeIndex: 0))
        let ranges = RangeRecorder()
        let runner = clusterRunner(
            store: store,
            clusters: [(id: "S1", start: 0, end: 2)],
            voiceprints: [:],
            capturedRanges: ranges
        )

        let result = try await runner.run(samples: Array(repeating: 0.1, count: 32_000), source: .mic, workspace: try makeWorkspace())

        #expect(result.segments.map(\.speakerId) == ["S1"])
        #expect(result.speakerEmbeddings.isEmpty)
        #expect(result.matchedSpeakerIDs.isEmpty)
        #expect(ranges.values == [SpeakerVoiceprintExtractor.SpeakerRange(speaker: "S1", start: 0, end: 2)])
    }

    /// Two clusters of one pass close to the same profile: only the closer one gets it.
    @Test
    func twoClustersCompetingForOneProfile() async throws {
        let modelContainer = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = SpeakerEmbeddingStore(modelContainer: modelContainer)
        let alice = normalizedEmbedding(length: 8, activeIndex: 0)
        try await store.enrollNamedSpeaker(name: "Alice", embedding: alice)
        var nearer = alice
        nearer[1] = 0.2
        var farther = alice
        farther[2] = 0.5
        let runner = clusterRunner(
            store: store,
            clusters: [(id: "S1", start: 0, end: 5), (id: "S2", start: 5, end: 10)],
            voiceprints: ["S1": farther, "S2": nearer]
        )

        let result = try await runner.run(samples: Array(repeating: 0.1, count: 160_000), source: .mic, workspace: try makeWorkspace())

        #expect(result.segments.map(\.speakerId) == ["S1", "Alice"])
        #expect(result.matchedSpeakerIDs == ["Alice": "Alice"])
    }

    @Test
    func makeVadConfigurationDerivesFromPipelineSettings() {
        var settings = LiveTranscriptionPipelineSettings.defaults
        settings.vadThreshold = 0.92
        settings.vadMinSpeechDuration = 0.45

        let (config, segmentation) = TranscriptionPassRunner.makeVadConfiguration(settings: settings)

        #expect(abs(config.defaultThreshold - 0.92) < 0.0001)
        #expect(abs(segmentation.minSpeechDuration - 0.45) < 0.0001)
        // FluidAudio defaults preserved, including the encoder-window cap.
        #expect(segmentation.maxSpeechDuration == VadSegmentationConfig.default.maxSpeechDuration)
    }

    @Test
    func confidenceGateDiscardsLowConfidenceSegments() async throws {
        var settings = LiveTranscriptionPipelineSettings.defaults
        settings.asrConfidenceGate = 0.5

        let runner = TranscriptionPassRunner(
            pipelineSettings: settings,
            segmentSpeech: { _ in
                [
                    TranscriptionPassRunner.SpeechSegment(startTime: 0, endTime: 1),
                    TranscriptionPassRunner.SpeechSegment(startTime: 2, endTime: 3)
                ]
            },
            makePassEngines: { _ in
                TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(
                            text: "thank you",
                            tokenTimings: [],
                            confidence: 0.2
                        )
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(segments: [], speakerDatabase: nil)
                    }
                )
            },
            alignTranscript: { fullText, _, _, source in
                Transcript(
                    fullText: fullText,
                    segments: fullText.isEmpty
                        ? []
                        : [TranscriptSegment(speakerId: "S1", text: fullText, startTime: 0, endTime: 1, audioSource: source)],
                    speakers: []
                )
            }
        )

        let workspace = try makeWorkspace()
        let passResult = try await runner.run(samples: Array(repeating: 0.1, count: 48_000), source: .mic, workspace: workspace)
        let segments = passResult.segments

        #expect(segments.isEmpty)
    }

    @Test
    func confidenceGateAtZeroKeepsAllSegments() async throws {
        let runner = TranscriptionPassRunner(
            pipelineSettings: .defaults,  // gate 0.0 = disabled
            segmentSpeech: { _ in
                [TranscriptionPassRunner.SpeechSegment(startTime: 0, endTime: 1)]
            },
            makePassEngines: { _ in
                TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "hello", tokenTimings: [], confidence: 0.01)
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(segments: [], speakerDatabase: nil)
                    }
                )
            },
            alignTranscript: { fullText, _, _, source in
                Transcript(
                    fullText: fullText,
                    segments: [TranscriptSegment(speakerId: "S1", text: fullText, startTime: 0, endTime: 1, audioSource: source)],
                    speakers: []
                )
            }
        )

        let workspace = try makeWorkspace()
        let passResult = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .mic, workspace: workspace)
        let segments = passResult.segments

        #expect(segments.count == 1)
        #expect(segments[0].text == "hello")
    }

    @Test
    func emitGauntletSanitizesLeadingPunctuationAndAppliesCleanupRules() async throws {
        var settings = LiveTranscriptionPipelineSettings.defaults
        settings.cleanupRules = [
            TranscriptCleanupRule(pattern: "um", position: .anywhere, wholeWord: true)
        ]

        let runner = TranscriptionPassRunner(
            pipelineSettings: settings,
            segmentSpeech: { _ in
                [TranscriptionPassRunner.SpeechSegment(startTime: 0, endTime: 1)]
            },
            makePassEngines: { _ in
                TranscriptionPassRunner.PassEngines(
                    transcribeChunk: { _, _ in
                        TranscriptionPassRunner.PassASRResult(text: "raw", tokenTimings: [])
                    },
                    diarize: { _ in
                        TranscriptionPassRunner.PassDiarizationResult(segments: [], speakerDatabase: nil)
                    }
                )
            },
            alignTranscript: { _, _, _, source in
                Transcript(
                    fullText: "irrelevant",
                    segments: [
                        TranscriptSegment(speakerId: "S1", text: ". um hello there", startTime: 0, endTime: 1, audioSource: source),
                        TranscriptSegment(speakerId: "S1", text: "...", startTime: 1, endTime: 2, audioSource: source),
                        TranscriptSegment(speakerId: "S1", text: "um", startTime: 2, endTime: 3, audioSource: source)
                    ],
                    speakers: []
                )
            }
        )

        let workspace = try makeWorkspace()
        let passResult = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .mic, workspace: workspace)
        let segments = passResult.segments

        // ". um hello there" → sanitized to "um hello there" → rule strips "um".
        // "..." is dropped by the sanitizer; "um" is emptied by the rule.
        #expect(segments.count == 1)
        #expect(segments[0].text == "hello there")
    }

    private func makeWorkspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Workspace(rootURL: root)
    }

    private func normalizedEmbedding(length: Int, activeIndex: Int) -> [Float] {
        var vector = Array(repeating: Float(0), count: length)
        vector[activeIndex] = 1
        return vector
    }
}

final class RangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [SpeakerVoiceprintExtractor.SpeakerRange] = []

    func record(_ ranges: [SpeakerVoiceprintExtractor.SpeakerRange]) {
        lock.withLock { self.ranges.append(contentsOf: ranges) }
    }

    var values: [SpeakerVoiceprintExtractor.SpeakerRange] {
        lock.withLock { ranges }
    }
}
