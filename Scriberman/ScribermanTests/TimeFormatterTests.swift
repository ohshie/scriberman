import XCTest
@testable import Scriberman

final class TimeFormatterTests: XCTestCase {
    func testZeroFormatsAsMinutesSeconds() {
        XCTAssertEqual(TimeFormatter.format(seconds: 0), "00:00")
    }

    func testSubHourFormatsAsMinutesSeconds() {
        XCTAssertEqual(TimeFormatter.format(seconds: 90), "01:30")
    }

    func testHourOrMoreFormatsAsHoursMinutesSeconds() {
        XCTAssertEqual(TimeFormatter.format(seconds: 3_661), "01:01:01")
    }

    func testNegativeInputIsTreatedAsZero() {
        XCTAssertEqual(TimeFormatter.format(seconds: -5), "00:00")
    }

    func testMillisecondsFormatIncludesHoursMinutesSecondsAndMilliseconds() {
        XCTAssertEqual(TimeFormatter.formatWithMilliseconds(seconds: 3_661.042), "01:01:01,042")
    }

    func testMillisecondsFormatTreatsNegativeInputAsZero() {
        XCTAssertEqual(TimeFormatter.formatWithMilliseconds(seconds: -1.5), "00:00:00,000")
    }
}
