import FluidAudio
import Foundation
import Testing
@testable import Scriberman

@MainActor
struct DictationModeSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "DictationModeSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test
    func absentValueIsReleaseTime() {
        #expect(DictationModeSettings(defaults: makeDefaults()).mode == .releaseTime)
    }

    @Test
    func selectedModePersistsAcrossInstances() {
        let defaults = makeDefaults()
        DictationModeSettings(defaults: defaults).setMode(.progressive)
        #expect(DictationModeSettings(defaults: defaults).mode == .progressive)
    }

    @Test
    func unknownStoredValueIsReleaseTime() {
        let defaults = makeDefaults()
        defaults.set("streaming", forKey: DictationModeSettings.modeKey)
        #expect(DictationModeSettings(defaults: defaults).mode == .releaseTime)
    }
}

struct ProgressiveTranscriptCommitterTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> WordTiming {
        WordTiming(word: text, startTime: start, endTime: end)
    }

    @Test
    func firstPassCommitsNothing() {
        var committer = ProgressiveTranscriptCommitter()
        let committed = committer.commit(words: [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8)], passStart: 0, passEnd: .infinity).words
        #expect(committed.isEmpty)
    }

    @Test
    func agreedPrefixIsCommittedAndLastWordHeldBack() {
        var committer = ProgressiveTranscriptCommitter()
        _ = committer.commit(words: [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8)], passStart: 0, passEnd: .infinity).words
        let committed = committer.commit(
            words: [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8), word("name", 1.1, 1.5)],
            passStart: 0, passEnd: .infinity
        ).words
        #expect(committed == ["Hello", "my"])
        #expect(committer.cutPoint == 0.8)
    }

    @Test
    func disagreementStopsTheCommitAtTheFirstDifference() {
        var committer = ProgressiveTranscriptCommitter()
        _ = committer.commit(words: [word("I", 0.1, 0.2), word("want", 0.3, 0.6)], passStart: 0, passEnd: .infinity).words
        let first = committer.commit(
            words: [word("I", 0.1, 0.2), word("went", 0.3, 0.6), word("to", 0.7, 0.8)],
            passStart: 0, passEnd: .infinity
        ).words
        #expect(first == ["I"])

        let second = committer.commit(
            words: [word("I", 0.1, 0.2), word("went", 0.3, 0.6), word("to", 0.7, 0.8), word("the", 0.9, 1.0)],
            passStart: 0, passEnd: .infinity
        ).words
        #expect(second == ["went", "to"])
    }

    @Test
    func changedPunctuationKeepsTheWordUncommitted() {
        var committer = ProgressiveTranscriptCommitter()
        _ = committer.commit(words: [word("Hello", 0.1, 0.4), word("world", 0.5, 0.9)], passStart: 0, passEnd: .infinity).words
        let first = committer.commit(
            words: [word("Hello", 0.1, 0.4), word("world.", 0.5, 0.9), word("How", 1.2, 1.4)],
            passStart: 0, passEnd: .infinity
        ).words
        #expect(first == ["Hello"])

        let second = committer.commit(
            words: [word("Hello", 0.1, 0.4), word("world.", 0.5, 0.9), word("How", 1.2, 1.4), word("are", 1.5, 1.7)],
            passStart: 0, passEnd: .infinity
        ).words
        #expect(second == ["world.", "How"])
    }

    @Test
    func repeatedWordsAreCommittedOnce() {
        var committer = ProgressiveTranscriptCommitter()
        let first = [word("no", 0.1, 0.3), word("no", 0.4, 0.6), word("no", 0.7, 0.9)]
        _ = committer.commit(words: first, passStart: 0, passEnd: .infinity).words
        let committed = committer.commit(words: first + [word("stop", 1.2, 1.5)], passStart: 0, passEnd: .infinity).words
        #expect(committed == ["no", "no", "no"])

        // The next pass re-decodes the same audio from the start; the committed words drop out.
        let again = committer.commit(words: first + [word("stop", 1.2, 1.5), word("now", 1.6, 1.9)], passStart: 0, passEnd: .infinity).words
        #expect(again == ["stop"])
    }

    @Test
    func passStartTrailsTheCutPointByTheLeftContext() {
        var committer = ProgressiveTranscriptCommitter()
        let words = [word("one", 0.2, 0.9), word("two", 1.0, 1.8), word("three", 2.0, 3.2), word("four", 3.4, 3.9)]
        _ = committer.commit(words: words, passStart: 0, passEnd: .infinity).words
        _ = committer.commit(words: words + [word("five", 4.1, 4.5)], passStart: 0, passEnd: .infinity).words
        #expect(committer.cutPoint == 3.9)
        #expect(abs(committer.passStartSeconds - 1.9) < 0.000_1)
    }

    @Test
    func wordsBeforeTheCutPointAreDroppedAndOverlappingNewWordsKept() {
        var committer = ProgressiveTranscriptCommitter()
        let early = [word("Hello", 0.1, 0.4), word("there", 0.5, 3.2)]
        _ = committer.commit(words: early, passStart: 0, passEnd: .infinity).words
        _ = committer.commit(words: early + [word("friend", 3.4, 3.8)], passStart: 0, passEnd: .infinity).words
        #expect(committer.cutPoint == 3.2)

        // Pass audio starts at 1.2 s. "there" is re-decoded with a later start (2.1–3.25),
        // midpoint 2.675 < 3.2: dropped. "friend" starts before the cut (3.1–3.6),
        // midpoint 3.35 > 3.2: kept.
        let tail = committer.remainingWords(
            words: [word("there", 0.9, 2.05), word("friend", 1.9, 2.4), word("again", 2.6, 3.0)],
            passStart: 1.2
        )
        #expect(tail == ["friend", "again"])
    }

    @Test
    func remainingWordsWithoutCommitsIsTheWholePass() {
        let committer = ProgressiveTranscriptCommitter()
        let tail = committer.remainingWords(words: [word("Hi", 0.1, 0.3), word("all", 0.4, 0.6)], passStart: 0)
        #expect(tail == ["Hi", "all"])
    }

    // MARK: - Right context

    /// A word ending exactly `rightContextSeconds` before the end of the pass audio commits.
    @Test
    func wordAtTheRightContextThresholdCommits() {
        var committer = ProgressiveTranscriptCommitter()
        let words = [word("a", 0.1, 0.5), word("b", 0.6, 0.9), word("c", 1.0, 1.2)]
        _ = committer.commit(words: words, passStart: 0, passEnd: 1.5)
        let committed = committer.commit(words: words + [word("d", 1.3, 1.6)], passStart: 0, passEnd: 2.0)
        #expect(committed.words == ["a"])
        #expect(committer.cutPoint == 0.5)
    }

    @Test
    func wordJustInsideTheRightContextIsHeldBack() {
        var committer = ProgressiveTranscriptCommitter()
        let words = [word("a", 0.1, 0.51), word("b", 0.6, 0.9)]
        _ = committer.commit(words: words, passStart: 0, passEnd: 1.5)
        let committed = committer.commit(words: words + [word("c", 1.0, 1.2)], passStart: 0, passEnd: 2.0)
        #expect(committed.words.isEmpty)
        #expect(!committer.hasCommitted)
    }

    /// Spec scenario "Held-back word is inserted once it has right context", with pass audio
    /// that starts after the start of the press.
    @Test
    func heldBackWordCommitsOnTheNextPassWithNonzeroPassStart() {
        var committer = ProgressiveTranscriptCommitter()
        let opening = [word("one", 0.2, 2.4), word("two", 2.5, 2.9), word("three", 3.0, 3.3)]
        _ = committer.commit(words: opening, passStart: 0, passEnd: 3.5)
        let first = committer.commit(words: opening, passStart: 0, passEnd: 4.0)
        #expect(first.words == ["one"])
        #expect(abs(committer.passStartSeconds - 0.4) < 0.000_1)

        // Pass audio starts at 0.4 s; word times are from there. "three" (press 3.0–3.3) is agreed
        // but ends after 4.5 - 1.5 = 3.0, so it waits.
        let second = committer.commit(
            words: [word("one", 0.0, 2.0), word("two", 2.1, 2.5), word("three", 2.6, 2.9), word("four", 3.2, 3.5)],
            passStart: 0.4,
            passEnd: 4.5
        )
        #expect(second.words == ["two"])

        // Pass audio starts at 0.9 s. "three" keeps its agreement and is old enough now.
        let third = committer.commit(
            words: [word("three", 2.1, 2.4), word("four", 2.7, 3.0), word("five", 3.3, 3.7)],
            passStart: 0.9,
            passEnd: 5.5
        )
        #expect(third.words == ["three", "four"])
    }

    /// Spec scenario "Rewrite inside the window is typed once": "two" never has the right
    /// context before the model rewrites the span, so the number is typed once, at release.
    @Test
    func rewriteInsideTheWindowIsTypedOnce() {
        var committer = ProgressiveTranscriptCommitter()
        let first = committer.commit(words: [word("two", 0.1, 0.4), word("to", 0.5, 0.7)], passStart: 0, passEnd: 1.2)
        let second = committer.commit(
            words: [word("two", 0.1, 0.4), word("to", 0.5, 0.7), word("three", 0.8, 1.2)],
            passStart: 0,
            passEnd: 1.6
        )
        let third = committer.commit(words: [word("2-3", 0.1, 1.2)], passStart: 0, passEnd: 2.0)
        #expect(first.words.isEmpty && second.words.isEmpty && third.words.isEmpty)

        let tail = committer.remainingWords(words: [word("2-3", 0.1, 1.2)], passStart: 0)
        #expect(tail == ["2-3"])
    }

    /// A rewrite over a committed word is reported with the right context that word had.
    @Test
    func straddlingWordIsReportedWithTheCommittedWordsRightContext() {
        var committer = ProgressiveTranscriptCommitter()
        let opening = committer.commit(words: [word("two", 0.1, 0.4), word("to", 0.5, 0.7)], passStart: 0, passEnd: 1.0)
        let committing = committer.commit(
            words: [word("two", 0.1, 0.4), word("to", 0.5, 0.7), word("three", 0.8, 1.2)],
            passStart: 0,
            passEnd: 2.0
        )
        #expect(committing.words == ["two"])
        #expect(opening.straddles.isEmpty && committing.straddles.isEmpty)
        #expect(committing.cutPointBefore == 0 && committing.cutPointAfter == 0.4)

        let rewrite = committer.commit(words: [word("2-3", 0.1, 1.2)], passStart: 0, passEnd: 2.5)
        let straddle = rewrite.straddles.first
        #expect(rewrite.straddles.count == 1)
        #expect(straddle?.startTime == 0.1 && straddle?.endTime == 1.2)
        #expect(abs((straddle?.committedWordRightContext ?? 0) - 1.6) < 0.000_1)
    }

    @Test
    func passWithOnlyNewWordsReportsNoStraddle() {
        var committer = ProgressiveTranscriptCommitter()
        let words = [word("a", 0.1, 0.4), word("b", 0.5, 0.8)]
        _ = committer.commit(words: words, passStart: 0, passEnd: 2.0)
        _ = committer.commit(words: words + [word("c", 0.9, 1.0)], passStart: 0, passEnd: 2.5)
        let later = committer.commit(words: words + [word("c", 0.9, 1.0), word("d", 1.1, 1.3)], passStart: 0, passEnd: 3.0)
        #expect(later.straddles.isEmpty)
    }
}

struct ProgressivePassLogTests {
    /// The per-pass log carries timings and counts only: no word of what the user said.
    @Test(.tags(.sourceLint))
    func passLogInterpolatesNoWordText() throws {
        let serviceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Services/Dictation/DictationService.swift")
        let source = try String(contentsOf: serviceURL, encoding: .utf8)
        let start = try #require(source.range(of: "private func logProgressivePass("))
        let end = try #require(source.range(of: "private func insertProgressive(", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])

        #expect(body.contains("result.words.count"))
        #expect(body.components(separatedBy: "result.words").count == body.components(separatedBy: "result.words.count").count)
        #expect(!body.contains(".word,") && !body.contains(".word)") && !body.contains("joined(separator: \" \")"))
        #expect(body.contains("privacy: .public"))
    }
}
