import XCTest
@testable import Scriberman

final class TranscriptionServiceTests: XCTestCase {
    func testMergeByTimestampInterleavedInput() async {
        let service = TranscriptionService()
        let segments = [
            TranscriptSegment(speakerId: "S1", text: "later mic", startTime: 2.0, endTime: 2.3, audioSource: .mic),
            TranscriptSegment(speakerId: "app:S1", text: "earlier app", startTime: 0.8, endTime: 1.0, audioSource: .app),
            TranscriptSegment(speakerId: "S2", text: "middle mic", startTime: 1.4, endTime: 1.8, audioSource: .mic)
        ]

        let merged = await service.mergeByTimestamp(segments)
        XCTAssertEqual(merged.map(\.text), ["earlier app", "middle mic", "later mic"])
    }

    func testMergeByTimestampMicOnlyInput() async {
        let service = TranscriptionService()
        let micSegments = [
            TranscriptSegment(speakerId: "S2", text: "second", startTime: 2.0, endTime: 2.2, audioSource: .mic),
            TranscriptSegment(speakerId: "S1", text: "first", startTime: 1.0, endTime: 1.2, audioSource: .mic)
        ]

        let merged = await service.mergeByTimestamp(micSegments)
        XCTAssertEqual(merged.map(\.text), ["first", "second"])
        XCTAssertTrue(merged.allSatisfy { $0.audioSource == .mic })
    }

    func testMergeByTimestampWithEmptyAppInputReturnsMicSegmentsOnly() async {
        let service = TranscriptionService()
        let micSegments = [
            TranscriptSegment(speakerId: "S1", text: "only mic", startTime: 0.5, endTime: 0.9, audioSource: .mic)
        ]
        let allSegments = micSegments + [TranscriptSegment]()

        let merged = await service.mergeByTimestamp(allSegments)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "only mic")
        XCTAssertEqual(merged[0].audioSource, .mic)
    }

    func testTranscribePassSilentAudioReturnsEmptySegments() async throws {
        let service = TranscriptionService(
            resampleAudioFile: { _ in [0, 0, 0, 0] },
            segmentSpeech: { _ in [] }
        )

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let audioURL = tempRoot.appendingPathComponent("silent.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data())
        let workspace = Workspace(rootURL: tempRoot)

        let (segments, embeddings) = try await service.transcribePassForTesting(url: audioURL, source: .app, workspace: workspace)
        XCTAssertEqual(segments, [])
        XCTAssertTrue(embeddings.isEmpty)
    }

    func testTranscribePassFromSamplesSilentAudioReturnsEmptySegments() async throws {
        let service = TranscriptionService(
            resampleAudioFile: { _ in [1, 2, 3, 4] },
            segmentSpeech: { _ in [] }
        )
        let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory)

        let (segments, embeddings) = try await service.transcribePassFromSamplesForTesting(
            samples: [0, 0, 0, 0],
            source: .mic,
            workspace: workspace
        )

        XCTAssertEqual(segments, [])
        XCTAssertTrue(embeddings.isEmpty)
    }

    func testTranscribeThrowsMissingAudioWhenMixdownURLIsNil() async {
        let service = TranscriptionService()
        let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory)
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 3,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: nil,
            mixdownURL: nil,
            title: "Session",
            status: .recorded
        )

        do {
            _ = try await service.transcribe(session: session, workspace: workspace)
            XCTFail("Expected missing audio file error.")
        } catch {
            guard case TranscriptionError.missingAudioFile = error else {
                XCTFail("Expected missingAudioFile, got \(error)")
                return
            }
        }
    }

    func testTranscribeUsesM4AExtractionAndRunsMicAndAppPasses() async throws {
        let recorder = SampleRecorder()
        let service = TranscriptionService(
            resampleAudioFile: { _ in
                XCTFail("resampleAudioFile should not be used for M4A extraction path")
                return []
            },
            segmentSpeech: { samples in
                await recorder.record(samples)
                return []
            },
            extractSamples: { _, _ in
                (mic: [1.0, 2.0], app: [3.0, 4.0])
            },
            prepareModelsHandler: { _ in
                await recorder.markPrepared()
            }
        )

        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 6,
            micAudioURL: "/tmp/mic.wav",
            appAudioURL: "/tmp/app.wav",
            mixdownURL: "/tmp/recording.m4a",
            title: "Session",
            status: .recorded
        )
        let workspace = Workspace(rootURL: FileManager.default.temporaryDirectory)

        let transcript = try await service.transcribe(session: session, workspace: workspace)

        XCTAssertTrue(transcript.segments.isEmpty)
        XCTAssertTrue(transcript.fullText.isEmpty)
        let captured = await recorder.captured
        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured.contains { $0 == [1.0, 2.0] })
        XCTAssertTrue(captured.contains { $0 == [3.0, 4.0] })
        let prepared = await recorder.prepared
        XCTAssertTrue(prepared)
    }
}

private actor SampleRecorder {
    private(set) var captured: [[Float]] = []
    private(set) var prepared: Bool = false

    func record(_ samples: [Float]) {
        captured.append(samples)
    }

    func markPrepared() {
        prepared = true
    }
}
