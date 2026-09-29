import FluidAudio
import Foundation

/// Decides which words of a progressive dictation are stable enough to type.
///
/// Each pass transcribes the audio from `passStartSeconds` to the end of what has
/// been captured. A word is committed when two consecutive passes agree on it and
/// on every word before it; the last word of the current pass is never committed,
/// because its ending (punctuation, case) can still change with more audio.
/// Committed words are never revisited.
struct ProgressiveTranscriptCommitter {
    /// Audio before the cut-point that each pass re-transcribes so the first new
    /// word is decoded with context. Words in it are dropped by timestamp.
    static let leftContextSeconds: TimeInterval = 2

    /// End of the last committed word, in seconds from the start of the press.
    private(set) var cutPoint: TimeInterval = 0
    private(set) var hasCommitted = false
    /// Uncommitted words of the previous pass, in press time.
    private var previous: [WordTiming]?

    /// Where the next pass starts, in seconds from the start of the press.
    var passStartSeconds: TimeInterval {
        max(0, cutPoint - Self.leftContextSeconds)
    }

    /// Feeds one pass and returns the words it commits, in spoken order.
    /// - Parameters:
    ///   - words: The pass's words, timed from the start of the pass audio.
    ///   - passStart: Where that pass audio started, in seconds from the start of the press.
    mutating func commit(words: [WordTiming], passStart: TimeInterval) -> [String] {
        let current = uncommitted(words, passStart: passStart)
        guard let previous else {
            self.previous = current
            return []
        }

        var agreed = 0
        while agreed < current.count - 1, agreed < previous.count, current[agreed].word == previous[agreed].word {
            agreed += 1
        }
        self.previous = Array(current[agreed...])
        guard agreed > 0 else { return [] }

        let committed = current[..<agreed]
        cutPoint = committed.last!.endTime
        hasCommitted = true
        return committed.map(\.word)
    }

    /// Returns every word of the final pass after the cut-point.
    func remainingWords(words: [WordTiming], passStart: TimeInterval) -> [String] {
        uncommitted(words, passStart: passStart).map(\.word)
    }

    /// Shifts a pass's words to press time and drops those already committed.
    /// A word belongs after the cut-point when its midpoint does, so a re-decoded
    /// committed word whose start moved slightly is still dropped, and a new word
    /// whose start slightly overlaps the cut-point is still kept.
    private func uncommitted(_ words: [WordTiming], passStart: TimeInterval) -> [WordTiming] {
        words.compactMap { word in
            let shifted = WordTiming(
                word: word.word,
                startTime: word.startTime + passStart,
                endTime: word.endTime + passStart
            )
            guard !hasCommitted || (shifted.startTime + shifted.endTime) / 2 > cutPoint else { return nil }
            return shifted
        }
    }
}
