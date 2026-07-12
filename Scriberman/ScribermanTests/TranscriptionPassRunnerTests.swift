import FluidAudio
import Foundation
import SwiftData
import Testing
@testable import Scriberman

struct TranscriptionPassRunnerTests {
    @Test
    func runReturnsEmptyWhenVADProducesNoSpeech() async throws {
        var engineCreated = false
        let runner = TranscriptionPassRunner(
            segmentSpeech: { _ in [] },
            makePassEngines: { _ in
                engineCreated = true
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
        let (segments, embeddings) = try await runner.run(samples: [0, 0, 0], source: .mic, workspace: workspace)

        #expect(segments.isEmpty)
        #expect(embeddings.isEmpty)
        #expect(!engineCreated)
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
                            speakerDatabase: ["cluster_1": [0.2, 0.8]]
                        )
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
        let (segments, embeddings) = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .app, workspace: workspace)

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
        try await store.enrollSpeaker(name: "Alice", embedding: embedding)

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
                            speakerDatabase: ["cluster_1": embedding]
                        )
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
        let (segments, embeddings) = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .mic, workspace: workspace)

        #expect(segments.count == 1)
        #expect(segments[0].speakerId == "Alice")
        #expect(embeddings["Alice"] != nil)
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
        let (segments, _) = try await runner.run(samples: Array(repeating: 0.1, count: 48_000), source: .mic, workspace: workspace)

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
        let (segments, _) = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .mic, workspace: workspace)

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
        let (segments, _) = try await runner.run(samples: Array(repeating: 0.1, count: 16_000), source: .mic, workspace: workspace)

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
