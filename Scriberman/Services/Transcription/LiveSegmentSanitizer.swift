import Foundation

/// Strips decoder-state punctuation artifacts from live segment text before
/// emission. Carried TDT decoder state defers a sentence's terminal
/// punctuation into the next chunk, producing segments that start with ". "
/// or consist of punctuation alone (design D2–D4).
enum LiveSegmentSanitizer {
    /// Sentence punctuation the decoder defers across chunk boundaries.
    /// Quotes, dashes, and parentheses can legitimately open a segment and
    /// are preserved (design D3).
    private static let strippableLeading: Set<Character> = [".", ",", "!", "?", ";", ":", "…"]

    /// Cleaned text ready for emission, or nil when the segment should be
    /// dropped because nothing alphanumeric remains after stripping.
    static func sanitize(_ text: String) -> String? {
        let stripped = String(text.drop { $0.isWhitespace || strippableLeading.contains($0) })
        guard stripped.contains(where: { $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return stripped
    }
}
