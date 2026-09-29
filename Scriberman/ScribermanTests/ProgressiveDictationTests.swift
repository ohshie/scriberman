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
        let committed = committer.commit(words: [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8)], passStart: 0)
        #expect(committed.isEmpty)
    }

    @Test
    func agreedPrefixIsCommittedAndLastWordHeldBack() {
        var committer = ProgressiveTranscriptCommitter()
        _ = committer.commit(words: [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8)], passStart: 0)
        let committed = committer.commit(
            words: [word("Hello", 0.1, 0.4), word("my", 0.5, 0.8), word("name", 1.1, 1.5)],
            passStart: 0
        )
        #expect(committed == ["Hello", "my"])
        #expect(committer.cutPoint == 0.8)
    }

    @Test
    func disagreementStopsTheCommitAtTheFirstDifference() {
        var committer = ProgressiveTranscriptCommitter()
        _ = committer.commit(words: [word("I", 0.1, 0.2), word("want", 0.3, 0.6)], passStart: 0)
        let first = committer.commit(
            words: [word("I", 0.1, 0.2), word("went", 0.3, 0.6), word("to", 0.7, 0.8)],
            passStart: 0
        )
        #expect(first == ["I"])

        let second = committer.commit(
            words: [word("I", 0.1, 0.2), word("went", 0.3, 0.6), word("to", 0.7, 0.8), word("the", 0.9, 1.0)],
            passStart: 0
        )
        #expect(second == ["went", "to"])
    }

    @Test
    func changedPunctuationKeepsTheWordUncommitted() {
        var committer = ProgressiveTranscriptCommitter()
        _ = committer.commit(words: [word("Hello", 0.1, 0.4), word("world", 0.5, 0.9)], passStart: 0)
        let first = committer.commit(
            words: [word("Hello", 0.1, 0.4), word("world.", 0.5, 0.9), word("How", 1.2, 1.4)],
            passStart: 0
        )
        #expect(first == ["Hello"])

        let second = committer.commit(
            words: [word("Hello", 0.1, 0.4), word("world.", 0.5, 0.9), word("How", 1.2, 1.4), word("are", 1.5, 1.7)],
            passStart: 0
        )
        #expect(second == ["world.", "How"])
    }

    @Test
    func repeatedWordsAreCommittedOnce() {
        var committer = ProgressiveTranscriptCommitter()
        let first = [word("no", 0.1, 0.3), word("no", 0.4, 0.6), word("no", 0.7, 0.9)]
        _ = committer.commit(words: first, passStart: 0)
        let committed = committer.commit(words: first + [word("stop", 1.2, 1.5)], passStart: 0)
        #expect(committed == ["no", "no", "no"])

        // The next pass re-decodes the same audio from the start; the committed words drop out.
        let again = committer.commit(words: first + [word("stop", 1.2, 1.5), word("now", 1.6, 1.9)], passStart: 0)
        #expect(again == ["stop"])
    }

    @Test
    func passStartTrailsTheCutPointByTheLeftContext() {
        var committer = ProgressiveTranscriptCommitter()
        let words = [word("one", 0.2, 0.9), word("two", 1.0, 1.8), word("three", 2.0, 3.2), word("four", 3.4, 3.9)]
        _ = committer.commit(words: words, passStart: 0)
        _ = committer.commit(words: words + [word("five", 4.1, 4.5)], passStart: 0)
        #expect(committer.cutPoint == 3.9)
        #expect(abs(committer.passStartSeconds - 1.9) < 0.000_1)
    }

    @Test
    func wordsBeforeTheCutPointAreDroppedAndOverlappingNewWordsKept() {
        var committer = ProgressiveTranscriptCommitter()
        let early = [word("Hello", 0.1, 0.4), word("there", 0.5, 3.2)]
        _ = committer.commit(words: early, passStart: 0)
        _ = committer.commit(words: early + [word("friend", 3.4, 3.8)], passStart: 0)
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
}
