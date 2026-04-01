import FluidAudio
import Foundation
import SwiftData
import XCTest
@testable import Scriberman

final class TranscriptionPassRunnerTests: XCTestCase {
    func testRunReturnsEmptyWhenVADProducesNoSpeech() async throws {
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

        XCTAssertTrue(segments.isEmpty)
        XCTAssertTrue(embeddings.isEmpty)
        XCTAssertFalse(engineCreated)
    }

    func testRunPrefixesAppSpeakerIDsInSegmentsAndEmbeddings() async throws {
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

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerId, "app:cluster_1")
        XCTAssertNotNil(embeddings["app:cluster_1"])
    }

    func testRunAppliesSpeakerMappingFromStore() async throws {
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

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerId, "Alice")
        XCTAssertNotNil(embeddings["Alice"])
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
