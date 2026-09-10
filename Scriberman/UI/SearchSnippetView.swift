import SwiftUI

/// One line of transcript text around a search match, with the match itself emphasised.
///
/// Leading and trailing ellipses mark a window cut out of a longer line, so a fragment is not read
/// as the whole thing.
struct SearchSnippetView: View {
    let snippet: SessionSearchSnippet

    var body: some View {
        Text(attributedText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var attributedText: AttributedString {
        var text = AttributedString(
            (snippet.isTruncatedAtStart ? "…" : "") + snippet.text + (snippet.isTruncatedAtEnd ? "…" : "")
        )

        // The match's offsets carry across because the ellipsis, when present, shifts everything by
        // exactly one character.
        let offset = snippet.isTruncatedAtStart ? 1 : 0
        let lower = snippet.text.distance(from: snippet.text.startIndex, to: snippet.matchRange.lowerBound) + offset
        let upper = snippet.text.distance(from: snippet.text.startIndex, to: snippet.matchRange.upperBound) + offset

        let characters = text.characters
        guard lower >= 0, upper <= characters.count, lower < upper else { return text }

        let start = characters.index(characters.startIndex, offsetBy: lower)
        let end = characters.index(characters.startIndex, offsetBy: upper)

        text[start..<end].foregroundColor = .primary
        text[start..<end].font = .caption.weight(.semibold)
        return text
    }
}
