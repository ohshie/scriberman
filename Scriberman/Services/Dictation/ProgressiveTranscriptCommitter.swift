import FluidAudio
import Foundation

/// Decides which words of a progressive dictation are stable enough to type.
///
/// Each pass transcribes the audio from `passStartSeconds` to the end of what has
/// been captured. A word is committed when two consecutive passes agree on it and
/// on every word before it, and it ends at least `rightContextSeconds` before the end
/// of the pass audio; the last word of the current pass is never committed, because
/// its ending (punctuation, case) can still change with more audio. Committed words
/// are never revisited.
struct ProgressiveTranscriptCommitter {
    /// Audio before the cut-point that each pass re-transcribes so the first new
    /// word is decoded with context. Words in it are dropped by timestamp.
    static let leftContextSeconds: TimeInterval = 2

    /// Audio a word needs after it in the committing pass. The model rewrites spans once it
    /// hears what follows ("two to three" becomes "2-3"); a word typed before that would be
    /// typed again in its rewritten form. Provisional until measured from real presses.
    static let rightContextSeconds: TimeInterval = 1.5

    /// What one pass did, for the per-pass log. Timings only, in seconds from the start of
    /// the press.
    struct PassResult: Equatable {
        /// A new word that starts before the cut-point and has its midpoint after it: the
        /// timing a rewrite of committed words leaves.
        struct Straddle: Equatable {
            var startTime: TimeInterval
            var endTime: TimeInterval
            /// Audio the last committed word had after it in the pass that committed it.
            var committedWordRightContext: TimeInterval?
        }

        var words: [String]
        var cutPointBefore: TimeInterval
        var cutPointAfter: TimeInterval
        var straddles: [Straddle]
    }

    /// End of the last committed word, in seconds from the start of the press.
    private(set) var cutPoint: TimeInterval = 0
    private(set) var hasCommitted = false
    /// Audio the last committed word had after it in the pass that committed it.
    private var lastCommitRightContext: TimeInterval?
    /// Uncommitted words of the previous pass, in press time.
    private var previous: [WordTiming]?

    /// Where the next pass starts, in seconds from the start of the press.
    var passStartSeconds: TimeInterval {
        max(0, cutPoint - Self.leftContextSeconds)
    }

    /// Feeds one pass and returns the words it commits, in spoken order, with what the
    /// per-pass log records.
    /// - Parameters:
    ///   - words: The pass's words, timed from the start of the pass audio.
    ///   - passStart: Where that pass audio started, in seconds from the start of the press.
    ///   - passEnd: Where that pass audio ended, in seconds from the start of the press.
    mutating func commit(words: [WordTiming], passStart: TimeInterval, passEnd: TimeInterval) -> PassResult {
        let cutPointBefore = cutPoint
        let current = uncommitted(words, passStart: passStart)
        let straddles = hasCommitted
            ? current.filter { $0.startTime < cutPointBefore }.map {
                PassResult.Straddle(
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    committedWordRightContext: lastCommitRightContext
                )
            }
            : []
        func result(_ committed: [String]) -> PassResult {
            PassResult(words: committed, cutPointBefore: cutPointBefore, cutPointAfter: cutPoint, straddles: straddles)
        }

        guard let previous else {
            self.previous = current
            return result([])
        }

        var agreed = 0
        while agreed < current.count - 1, agreed < previous.count, current[agreed].word == previous[agreed].word {
            agreed += 1
        }
        // Agreed words without enough audio after them wait for a later pass. They stay in
        // `previous`, so that pass can commit them as soon as they are old enough.
        let latestEnd = passEnd - Self.rightContextSeconds
        var committedCount = 0
        while committedCount < agreed, current[committedCount].endTime <= latestEnd {
            committedCount += 1
        }
        self.previous = Array(current[committedCount...])
        guard committedCount > 0 else { return result([]) }

        let committed = current[..<committedCount]
        cutPoint = committed.last!.endTime
        lastCommitRightContext = passEnd - cutPoint
        hasCommitted = true
        return result(committed.map(\.word))
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
