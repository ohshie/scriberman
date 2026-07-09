import Foundation

/// One user-configured cleanup rule applied to live transcript segments at
/// emit time. Matching is always case-insensitive (design D1).
struct TranscriptCleanupRule: Codable, Equatable, Identifiable, Sendable {
    enum Position: String, Codable, CaseIterable, Sendable {
        /// Matches only at the beginning of the segment text.
        case start
        /// Matches only at the end of the segment text.
        case end
        /// Matches every occurrence in the segment text.
        case anywhere
    }

    var id: UUID
    /// Literal text to match — no regex or glob. Empty patterns are ignored
    /// by the engine.
    var pattern: String
    var position: Position
    /// When true, the pattern only matches whole words: any non-alphanumeric
    /// character counts as a word boundary.
    var wholeWord: Bool

    init(
        id: UUID = UUID(),
        pattern: String = "",
        position: Position = .anywhere,
        wholeWord: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.position = position
        self.wholeWord = wholeWord
    }
}
