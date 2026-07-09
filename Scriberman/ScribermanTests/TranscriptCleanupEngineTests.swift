import Foundation
import Testing
@testable import Scriberman

@Suite
struct TranscriptCleanupEngineTests {
    private func rule(
        _ pattern: String,
        _ position: TranscriptCleanupRule.Position = .anywhere,
        wholeWord: Bool = true
    ) -> TranscriptCleanupRule {
        TranscriptCleanupRule(pattern: pattern, position: position, wholeWord: wholeWord)
    }

    // MARK: - No-ops

    @Test
    func emptyRuleListReturnsInputUnchanged() {
        #expect(TranscriptCleanupEngine.apply([], to: "hello  world ") == "hello  world ")
    }

    @Test
    func emptyPatternRuleIsIgnored() {
        #expect(TranscriptCleanupEngine.apply([rule(""), rule("   ")], to: "hello world") == "hello world")
    }

    @Test
    func nonMatchingRuleLeavesTextUnchanged() {
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "hello world") == "hello world")
    }

    // MARK: - Whole-word semantics

    @Test
    func wholeWordDoesNotMatchInsideLongerWord() {
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "a huge deal") == "a huge deal")
    }

    @Test
    func wholeWordMatchesDespiteAttachedPunctuation() {
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "That's it, huh.") == "That's it.")
    }

    @Test
    func caseInsensitiveMatch() {
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "Huh, okay") == "okay")
    }

    @Test
    func anywhereRemovesAllOccurrences() {
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "huh well huh okay") == "well okay")
    }

    @Test
    func removalPreservesInteriorApostropheWords() {
        #expect(TranscriptCleanupEngine.apply([rule("damn")], to: "it's a damn fine day") == "it's a fine day")
    }

    @Test
    func multiWordPatternMatchesTokenSequence() {
        #expect(TranscriptCleanupEngine.apply([rule("you know")], to: "so you know it works") == "so it works")
    }

    // MARK: - Position anchoring

    @Test
    func startRuleMatchesOnlyAtBeginning() {
        #expect(TranscriptCleanupEngine.apply([rule("huh", .start)], to: "huh, that's it") == "that's it")
        #expect(TranscriptCleanupEngine.apply([rule("huh", .start)], to: "that's it, huh") == "that's it, huh")
    }

    @Test
    func endRuleAnchorsPastTrailingPunctuation() {
        #expect(TranscriptCleanupEngine.apply([rule("huh", .end)], to: "That's it, huh.") == "That's it.")
        #expect(TranscriptCleanupEngine.apply([rule("huh", .end)], to: "huh, that's it") == "huh, that's it")
    }

    @Test
    func startAndEndRemoveAtMostOneOccurrence() {
        #expect(TranscriptCleanupEngine.apply([rule("huh", .start)], to: "huh huh okay") == "huh okay")
        #expect(TranscriptCleanupEngine.apply([rule("huh", .end)], to: "okay huh huh") == "okay huh")
    }

    // MARK: - Drop signaling

    @Test
    func segmentReducedToNothingIsDropped() {
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "huh") == nil)
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "huh huh.") == nil)
    }

    @Test
    func segmentLeftWithOnlyPunctuationIsDropped() {
        #expect(TranscriptCleanupEngine.apply([rule("huh")], to: "huh...") == nil)
    }

    // MARK: - Rule chaining

    @Test
    func rulesApplyInOrderOnPreviousOutput() {
        let rules = [rule("huh"), rule("okay", .end)]
        #expect(TranscriptCleanupEngine.apply(rules, to: "well huh okay") == "well")
    }

    @Test
    func chainedRulesCanEmptyTheSegment() {
        let rules = [rule("huh"), rule("okay")]
        #expect(TranscriptCleanupEngine.apply(rules, to: "huh okay") == nil)
    }

    // MARK: - Substring (non-whole-word) semantics

    @Test
    func substringAnywhereRemovesAllOccurrencesAndCollapsesWhitespace() {
        #expect(
            TranscriptCleanupEngine.apply(
                [rule("damn", wholeWord: false)],
                to: "a damn fine damn day"
            ) == "a fine day"
        )
    }

    @Test
    func substringMatchesInsideWords() {
        #expect(TranscriptCleanupEngine.apply([rule("huh", wholeWord: false)], to: "a huhge deal") == "a ge deal")
    }

    @Test
    func substringStartAnchorsLiterally() {
        #expect(
            TranscriptCleanupEngine.apply(
                [rule(". ", .start, wholeWord: false)],
                to: ". and then"
            ) == "and then"
        )
        #expect(
            TranscriptCleanupEngine.apply(
                [rule(". ", .start, wholeWord: false)],
                to: "and. then"
            ) == "and. then"
        )
    }

    @Test
    func substringIsCaseInsensitive() {
        #expect(TranscriptCleanupEngine.apply([rule("DAMN", wholeWord: false)], to: "damn right") == "right")
    }
}
