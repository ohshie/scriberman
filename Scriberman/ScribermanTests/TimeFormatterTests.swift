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

    @Test
    func millisecondsFormatIncludesHoursMinutesSecondsAndMilliseconds() {
        #expect(TimeFormatter.formatWithMilliseconds(seconds: 3_661.042) == "01:01:01,042")
    }

    @Test
    func millisecondsFormatTreatsNegativeInputAsZero() {
        #expect(TimeFormatter.formatWithMilliseconds(seconds: -1.5) == "00:00:00,000")
    }
}
