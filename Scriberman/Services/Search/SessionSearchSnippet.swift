import Foundation

/// Where a query matched inside a session's transcript, and enough text around it to read.
///
/// Built by `TranscriptSearchState` — the matcher the in-transcript find bar uses — so a result and
/// the session it opens cannot disagree about what matched or where. `blockID` is that matcher's
/// own block identity, which is what lets the study view scroll to it.
@MainActor
struct SessionSearchMatch: Equatable {
    let blockID: UUID
    let snippet: SessionSearchSnippet
}

/// A readable window of transcript text around a match.
///
/// `matchRange` indexes into `text`, not into the block, so a row can highlight the match without
/// knowing where the window was cut.
struct SessionSearchSnippet: Equatable {
    let text: String
    let matchRange: Range<String.Index>

    /// Whether text was cut from the start or the end, so the view can mark it as a fragment.
    let isTruncatedAtStart: Bool
    let isTruncatedAtEnd: Bool
}

@MainActor
enum SessionSearchSnippetBuilder {
    /// How much text to keep on either side of the match. Enough for the line to carry its own
    /// sense, short enough to sit in a list row.
    static let leadingContext = 32
    static let trailingContext = 72

    /// Locates the first match for `query` in `transcript` and builds a snippet around it.
    ///
    /// Returns `nil` when the query matches nothing in the transcript — a session can be in the
    /// results on its title alone, and that result carries no snippet.
    static func match(query: String, in transcript: Transcript) -> SessionSearchMatch? {
        let blocks = TranscriptGrouper.makeBlocks(from: transcript)
        let state = TranscriptSearchState()
        state.query = query
        state.update(blocks: blocks)

        guard let match = state.currentMatch,
              let block = blocks.first(where: { $0.id == match.blockID }) else {
            return nil
        }

        return SessionSearchMatch(
            blockID: match.blockID,
            snippet: snippet(around: match.range, in: block.text)
        )
    }

    /// Cuts a window around `range`, moved out to word boundaries so a snippet never starts or ends
    /// mid-word.
    static func snippet(around range: Range<String.Index>, in text: String) -> SessionSearchSnippet {
        let start = wordBoundary(
            from: text.index(range.lowerBound, offsetBy: -leadingContext, limitedBy: text.startIndex)
                ?? text.startIndex,
            in: text,
            searchingForward: false
        )
        let end = wordBoundary(
            from: text.index(range.upperBound, offsetBy: trailingContext, limitedBy: text.endIndex)
                ?? text.endIndex,
            in: text,
            searchingForward: true
        )

        let window = String(text[start..<end])
        // The match's position within the window, recomputed from the offsets rather than carried
        // over: indices belong to the string they were made from.
        let lowerOffset = text.distance(from: start, to: range.lowerBound)
        let upperOffset = text.distance(from: start, to: range.upperBound)
        let matchStart = window.index(window.startIndex, offsetBy: lowerOffset)
        let matchEnd = window.index(window.startIndex, offsetBy: upperOffset)

        return SessionSearchSnippet(
            text: window,
            matchRange: matchStart..<matchEnd,
            isTruncatedAtStart: start > text.startIndex,
            isTruncatedAtEnd: end < text.endIndex
        )
    }

    /// Moves an index to the nearest whitespace boundary, in the direction that keeps the match in
    /// view: backwards for the start of the window, forwards for its end.
    private static func wordBoundary(
        from index: String.Index,
        in text: String,
        searchingForward: Bool
    ) -> String.Index {
        if searchingForward {
            guard index < text.endIndex else { return text.endIndex }
            var cursor = index
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            return cursor
        }

        guard index > text.startIndex else { return text.startIndex }
        var cursor = index
        while cursor > text.startIndex, !text[text.index(before: cursor)].isWhitespace {
            cursor = text.index(before: cursor)
        }
        return cursor
    }
}
