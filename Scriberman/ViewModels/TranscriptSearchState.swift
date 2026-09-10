import Foundation
import Observation

@MainActor
struct SearchMatch: Equatable {
    let blockID: UUID
    let range: Range<String.Index>
}

@MainActor
@Observable
final class TranscriptSearchState {
    var query = ""
    private(set) var matches: [SearchMatch] = []
    private(set) var currentIndex = 0

    var currentMatch: SearchMatch? {
        guard matches.indices.contains(currentIndex) else {
            return nil
        }

        return matches[currentIndex]
    }

    var summary: String {
        guard matches.isEmpty == false else {
            return ""
        }

        return "\(currentIndex + 1) of \(matches.count)"
    }

    func update(blocks: [TranscriptBlock]) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            matches = []
            currentIndex = 0
            return
        }

        matches = blocks.flatMap { block in
            ranges(for: trimmedQuery, in: block.text).map { range in
                SearchMatch(blockID: block.id, range: range)
            }
        }
        currentIndex = 0
    }

    /// Selects the first match inside `blockID`, leaving the selection alone when that block holds
    /// none.
    ///
    /// How an app-wide search result opens the session it points at: the result already knows which
    /// block matched, and this puts the find bar on that match rather than on the first one in the
    /// transcript.
    func selectFirstMatch(inBlock blockID: UUID) {
        guard let index = matches.firstIndex(where: { $0.blockID == blockID }) else { return }
        currentIndex = index
    }

    func next() {
        guard matches.isEmpty == false else {
            return
        }

        currentIndex = (currentIndex + 1) % matches.count
    }

    func previous() {
        guard matches.isEmpty == false else {
            return
        }

        currentIndex = (currentIndex - 1 + matches.count) % matches.count
    }

    func ranges(in block: TranscriptBlock) -> [Range<String.Index>] {
        matches
            .filter { $0.blockID == block.id }
            .map(\.range)
    }

    func activeRange(in block: TranscriptBlock) -> Range<String.Index>? {
        guard currentMatch?.blockID == block.id else {
            return nil
        }

        return currentMatch?.range
    }

    private func ranges(for query: String, in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStartIndex = text.startIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        while searchStartIndex < text.endIndex,
              let range = text.range(of: query, options: options, range: searchStartIndex..<text.endIndex) {
            ranges.append(range)
            searchStartIndex = range.upperBound
        }

        return ranges
    }
}
