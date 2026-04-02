import MarkdownUI
import XCTest
@testable import Scriberman

final class MarkdownRendererTests: XCTestCase {
    private let renderer = MarkdownRenderer()

    func testRenderIncludesSessionTitleAsH1() {
        let markdown = renderer.renderMarkdown(session: makeSession(title: "Sprint Review"), transcript: makeTranscript())
        XCTAssertTrue(markdown.hasPrefix("# Sprint Review\n"))
    }

    func testRenderIncludesSpeakerAndRangeFormatting() {
        let markdown = renderer.renderMarkdown(session: makeSession(), transcript: makeTranscript())

        XCTAssertTrue(markdown.contains("**Speaker 1** [00:00 – 00:02]"))
        XCTAssertTrue(markdown.contains("**Speaker 2** [00:03 – 00:05]"))
        XCTAssertTrue(markdown.contains("hello"))
        XCTAssertTrue(markdown.contains("there"))
    }

    func testRenderSortsSegmentsByStartTime() {
        let transcript = Transcript(
            fullText: "first second",
            segments: [
                TranscriptSegment(speakerId: "S2", text: "second", startTime: 3, endTime: 5),
                TranscriptSegment(speakerId: "S1", text: "first", startTime: 0, endTime: 2)
            ],
            speakers: [
                TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#4F46E5"),
                TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#16A34A")
            ]
        )

        let markdown = renderer.renderMarkdown(session: makeSession(), transcript: transcript)
        let firstIndex = markdown.range(of: "first")
        let secondIndex = markdown.range(of: "second")

        XCTAssertNotNil(firstIndex)
        XCTAssertNotNil(secondIndex)
        XCTAssertLessThan(firstIndex!.lowerBound, secondIndex!.lowerBound)
    }

    func testDefaultFileNameSanitizesSlash() {
        XCTAssertEqual(renderer.defaultFileName(for: "Recording 03/27"), "Recording 03-27.md")
    }

    func testDefaultFileNameFallbackForEmptyTitle() {
        XCTAssertEqual(renderer.defaultFileName(for: ""), "Transcript.md")
    }

    func testMarkdownUIImportCompiles() {
        _ = Markdown("**MarkdownUI**")
    }

    private func makeSession(title: String = "Session") -> RecordingSession {
        RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 5,
            micAudioURL: "/tmp/audio.wav",
            title: title,
            status: .done
        )
    }

    private func makeTranscript() -> Transcript {
        Transcript(
            fullText: "hello there",
            segments: [
                TranscriptSegment(speakerId: "S2", text: "there", startTime: 3, endTime: 5),
                TranscriptSegment(speakerId: "S1", text: "hello", startTime: 0, endTime: 2)
            ],
            speakers: [
                TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#4F46E5"),
                TranscriptSpeaker(id: "S2", label: "Speaker 2", colorHex: "#16A34A")
            ]
        )
    }
}
