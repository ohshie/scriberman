import MarkdownUI
import Foundation
import Testing
@testable import Scriberman

@MainActor
struct MarkdownRendererTests {
    private let renderer = MarkdownRenderer()

    @Test
    func renderIncludesSessionTitleAsH1() {
        let markdown = renderer.renderMarkdown(session: makeSession(title: "Sprint Review"), transcript: makeTranscript())
        #expect(markdown.hasPrefix("# Sprint Review\n"))
    }

    @Test
    func renderIncludesSpeakerAndRangeFormatting() {
        let markdown = renderer.renderMarkdown(session: makeSession(), transcript: makeTranscript())

        #expect(markdown.contains("**Speaker 1** [00:00 – 00:02]"))
        #expect(markdown.contains("**Speaker 2** [00:03 – 00:05]"))
        #expect(markdown.contains("hello"))
        #expect(markdown.contains("there"))
    }

    @Test
    func renderSortsSegmentsByStartTime() {
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

        #expect(firstIndex != nil)
        #expect(secondIndex != nil)
        #expect(firstIndex!.lowerBound < secondIndex!.lowerBound)
    }

    @Test
    func defaultFileNameSanitizesSlash() {
        #expect(renderer.defaultFileName(for: "Recording 03/27") == "Recording 03-27.md")
    }

    @Test
    func defaultFileNameFallbackForEmptyTitle() {
        #expect(renderer.defaultFileName(for: "") == "Transcript.md")
    }

    @Test
    func markdownUIImportCompiles() {
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
