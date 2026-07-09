import Testing
@testable import Scriberman

@Suite
struct LiveSegmentSanitizerTests {
    @Test
    func stripsLeadingOrphanPeriod() {
        #expect(LiveSegmentSanitizer.sanitize(". Yeah and then we should go") == "Yeah and then we should go")
    }

    @Test
    func stripsLeadingPunctuationRun() {
        #expect(LiveSegmentSanitizer.sanitize("... okay") == "okay")
    }

    @Test
    func stripsMixedLeadingPunctuationAndWhitespace() {
        #expect(LiveSegmentSanitizer.sanitize(" . , right") == "right")
    }

    @Test
    func dropsPunctuationOnlyText() {
        #expect(LiveSegmentSanitizer.sanitize(".") == nil)
        #expect(LiveSegmentSanitizer.sanitize(". .") == nil)
        #expect(LiveSegmentSanitizer.sanitize("?!…") == nil)
    }

    @Test
    func dropsEmptyString() {
        #expect(LiveSegmentSanitizer.sanitize("") == nil)
        #expect(LiveSegmentSanitizer.sanitize("   ") == nil)
    }

    @Test
    func dropsNonAlphanumericSymbols() {
        #expect(LiveSegmentSanitizer.sanitize("- —") == nil)
    }

    @Test
    func passesCleanTextUnchanged() {
        #expect(LiveSegmentSanitizer.sanitize("That's what I was thinking") == "That's what I was thinking")
    }

    @Test
    func preservesLeadingQuote() {
        #expect(LiveSegmentSanitizer.sanitize("«Hello there»") == "«Hello there»")
    }

    @Test
    func preservesLeadingDashBeforeWord() {
        #expect(LiveSegmentSanitizer.sanitize("- right, okay") == "- right, okay")
    }

    @Test
    func countsNonASCIILettersAsContent() {
        #expect(LiveSegmentSanitizer.sanitize(". Привет") == "Привет")
        #expect(LiveSegmentSanitizer.sanitize("日本語") == "日本語")
    }

    @Test
    func countsDigitsAsContent() {
        #expect(LiveSegmentSanitizer.sanitize(". 42") == "42")
    }
}
