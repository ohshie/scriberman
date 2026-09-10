import Testing
@testable import Scriberman

struct TimeFormatterTests {
    @Test
    func zeroFormatsAsMinutesSeconds() {
        #expect(TimeFormatter.format(seconds: 0) == "00:00")
    }

    @Test
    func subHourFormatsAsMinutesSeconds() {
        #expect(TimeFormatter.format(seconds: 90) == "01:30")
    }

    @Test
    func hourOrMoreFormatsAsHoursMinutesSeconds() {
        #expect(TimeFormatter.format(seconds: 3_661) == "01:01:01")
    }

    @Test
    func negativeInputIsTreatedAsZero() {
        #expect(TimeFormatter.format(seconds: -5) == "00:00")
    }

    // MARK: - The form shown on screen

    @Test
    func displayFormatDropsTheLeadingZero() {
        #expect(TimeFormatter.displayFormat(seconds: 95) == "1:35")
        #expect(TimeFormatter.displayFormat(seconds: 18) == "0:18")
    }

    @Test
    func displayFormatKeepsHoursWhenThereAreAny() {
        #expect(TimeFormatter.displayFormat(seconds: 3_731) == "1:02:11")
    }

    @Test
    func displayFormatTruncatesRatherThanRounding() {
        // A 94.6 s recording has not reached 1:35, and its player counts up to 1:34.
        #expect(TimeFormatter.displayFormat(seconds: 94.6) == "1:34")
    }

    @Test
    func displayFormatTreatsNegativeInputAsZero() {
        #expect(TimeFormatter.displayFormat(seconds: -5) == "0:00")
    }

    /// Exported markdown specifies zero-padded `MM:SS`. The display form is the one that changed.
    @Test
    func exportFormatStaysPadded() {
        #expect(TimeFormatter.format(seconds: 95) == "01:35")
    }

    @Test
    func millisecondsFormatIncludesHoursMinutesSecondsAndMilliseconds() {
        #expect(TimeFormatter.formatWithMilliseconds(seconds: 3_661.042) == "01:01:01,042")
    }

    @Test
    func millisecondsFormatTreatsNegativeInputAsZero() {
        #expect(TimeFormatter.formatWithMilliseconds(seconds: -1.5) == "00:00:00,000")
    }
}
