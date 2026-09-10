import Foundation
import Testing
@testable import Scriberman

/// Stage two of app-wide search: what a transcript result carries, and that it agrees with what the
/// study view finds for the same query.
@MainActor
struct SessionSearchSnippetTests {
    private func transcript(_ lines: [String]) -> Transcript {
        let segments = lines.enumerated().map { index, line in
            TranscriptSegment(
                speakerId: "speaker-\(index)",
                text: line,
                startTime: Float(index),
                endTime: Float(index) + 1
            )
        }
        return Transcript(
            fullText: lines.joined(separator: " "),
            segments: segments,
            speakers: lines.indices.map {
                TranscriptSpeaker(id: "speaker-\($0)", label: "Speaker \($0)", colorHex: "#112233")
            }
        )
    }

    @Test
    func testATranscriptMatchCarriesASnippetAndABlockID() throws {
        let transcript = transcript([
            "Nothing relevant in this first line at all.",
            "We should postpone the migration until the audit clears.",
        ])

        let match = try #require(SessionSearchSnippetBuilder.match(query: "migration", in: transcript))

        #expect(match.snippet.text.contains("migration"))
        #expect(String(match.snippet.text[match.snippet.matchRange]) == "migration")
        #expect(match.blockID == transcript.segments[1].id)
    }

    @Test
    func testAQueryThatIsNotInTheTranscriptHasNoMatch() {
        let transcript = transcript(["Nothing relevant here."])

        #expect(SessionSearchSnippetBuilder.match(query: "migration", in: transcript) == nil)
    }

    /// The identity the study view scrolls to is the same one the result carries, because both come
    /// from the same matcher over the same blocks.
    @Test
    func testTheReportedMatchIsAmongThoseTheStudyViewFinds() throws {
        let transcript = transcript([
            "First line, nothing here.",
            "The migration comes up twice: migration.",
        ])

        let result = try #require(SessionSearchSnippetBuilder.match(query: "migration", in: transcript))

        let studyState = TranscriptSearchState()
        studyState.query = "migration"
        studyState.update(blocks: TranscriptGrouper.makeBlocks(from: transcript))

        #expect(studyState.matches.contains { $0.blockID == result.blockID })
        #expect(studyState.currentMatch?.blockID == result.blockID)
    }

    @Test
    func testMatchingIgnoresCaseAndDiacritics() throws {
        let transcript = transcript(["We met at the café before the standup."])

        let match = try #require(SessionSearchSnippetBuilder.match(query: "CAFE", in: transcript))

        #expect(String(match.snippet.text[match.snippet.matchRange]).lowercased() == "café")
    }

    // MARK: - The window

    @Test
    func testAShortLineIsNotTruncated() throws {
        let text = "Short enough to show whole."
        let range = try #require(text.range(of: "whole"))

        let snippet = SessionSearchSnippetBuilder.snippet(around: range, in: text)

        #expect(snippet.text == text)
        #expect(!snippet.isTruncatedAtStart)
        #expect(!snippet.isTruncatedAtEnd)
    }

    @Test
    func testALongLineIsCutOnBothSidesAtWordBoundaries() throws {
        let padding = String(repeating: "context ", count: 40)
        let text = padding + "migration " + padding
        let range = try #require(text.range(of: "migration"))

        let snippet = SessionSearchSnippetBuilder.snippet(around: range, in: text)

        #expect(snippet.text.count < text.count)
        #expect(snippet.isTruncatedAtStart)
        #expect(snippet.isTruncatedAtEnd)
        // Cut at whitespace, so no half word survives at either edge.
        #expect(snippet.text.hasPrefix("context"))
        #expect(snippet.text.hasSuffix("context"))
        #expect(String(snippet.text[snippet.matchRange]) == "migration")
    }

    @Test
    func testTheMatchRangeIndexesIntoTheSnippetNotTheSource() throws {
        let text = String(repeating: "word ", count: 30) + "migration tail"
        let range = try #require(text.range(of: "migration"))

        let snippet = SessionSearchSnippetBuilder.snippet(around: range, in: text)

        // Indices belong to the string they were made from: using the source range here would
        // either trap or quote the wrong text.
        #expect(String(snippet.text[snippet.matchRange]) == "migration")
    }
}
