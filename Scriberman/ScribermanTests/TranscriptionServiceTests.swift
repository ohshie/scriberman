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

        let segments = try await service.transcribePassForTesting(url: audioURL, source: .app, workspace: workspace)
        XCTAssertEqual(segments, [])
    }
}
