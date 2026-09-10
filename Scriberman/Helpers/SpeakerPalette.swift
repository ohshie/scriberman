import Foundation

/// The colours speakers are drawn in, in assignment order.
///
/// One list, in one place, because there are three writers of `TranscriptSpeaker` — the live path,
/// the batch path and retranscription — and they disagreed: two of them indexed a palette while the
/// live path gave every speaker the same system blue, so every recording transcribed as it was made
/// showed a conversation in one colour.
///
/// Colour is also derived at display time from a speaker's position, so transcripts already stored
/// with one colour for everybody are drawn correctly without being rewritten.
enum SpeakerPalette {
    static let colorHexes = ["#4F46E5", "#16A34A", "#EA580C", "#0891B2", "#DC2626", "#7C3AED"]

    /// The colour for the speaker at `index` in a transcript's own speaker list. Wraps, so a
    /// transcript with more speakers than colours repeats rather than running out.
    static func colorHex(at index: Int) -> String {
        colorHexes[abs(index) % colorHexes.count]
    }
}
