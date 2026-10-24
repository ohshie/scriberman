import Foundation
import SwiftData
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

    @Test
    func displayFormatGainsHoursAtTheHour() {
        #expect(TimeFormatter.displayFormat(seconds: 3_599) == "59:59")
        #expect(TimeFormatter.displayFormat(seconds: 3_600) == "1:00:00")
        #expect(TimeFormatter.displayFormat(seconds: 4_500) == "1:15:00")
    }

    /// The player reports NaN duration until the asset loads.
    @Test
    func displayFormatTreatsNonFiniteInputAsZero() {
        #expect(TimeFormatter.displayFormat(seconds: .nan) == "0:00")
        #expect(TimeFormatter.displayFormat(seconds: .infinity) == "0:00")
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

    // MARK: - Dates shown on screen

    private static let utc = TimeZone(identifier: "UTC")!

    /// 18 Oct 2026, 16:09 UTC: the date in the screenshot that showed two orders on one screen.
    private static let sample: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 16, minute: 9))!
    }()

    private static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        calendar.locale = Locale(identifier: identifier)
        return calendar
    }

    private static func dateTime(_ identifier: String) -> String {
        TimeFormatter.displayDateTime(sample, locale: Locale(identifier: identifier), calendar: calendar(identifier))
    }

    private static func monthDay(_ identifier: String) -> String {
        TimeFormatter.displayMonthDay(sample, locale: Locale(identifier: identifier), calendar: calendar(identifier))
    }

    private static func monthDayTime(_ identifier: String) -> String {
        TimeFormatter.displayMonthDayTime(sample, locale: Locale(identifier: identifier), calendar: calendar(identifier))
    }

    @Test
    func displayDateTimeFollowsTheRegion() {
        #expect(Self.dateTime("en_US") == "Oct 18, 2026 at 4:09\u{202F}PM")
        #expect(Self.dateTime("en_GB") == "18 Oct 2026 at 16:09")
        #expect(Self.dateTime("ru_RU") == "18 окт. 2026\u{202F}г., 16:09")
    }

    @Test
    func displayDateTimeFollowsTheClockSetting() {
        #expect(Self.dateTime("en_US@hours=h23") == "Oct 18, 2026 at 16:09")
        #expect(Self.dateTime("en_GB@hours=h12") == "18 Oct 2026 at 4:09\u{202F}pm")
    }

    @Test
    func displayMonthDayFollowsTheRegion() {
        #expect(Self.monthDay("en_US") == "Oct 18")
        #expect(Self.monthDay("en_GB") == "18 Oct")
        #expect(Self.monthDay("ru_RU") == "18 окт.")
    }

    @Test
    func displayMonthDayTimeFollowsTheRegionAndClock() {
        #expect(Self.monthDayTime("en_US") == "Oct 18 at 4:09\u{202F}PM")
        #expect(Self.monthDayTime("en_GB") == "18 Oct at 16:09")
        #expect(Self.monthDayTime("ru_RU") == "18 окт., 16:09")
        #expect(Self.monthDayTime("en_US@hours=h23") == "Oct 18 at 16:09")
    }

    /// The header facts line and the session list put day and month in the same order.
    @Test(arguments: ["en_US", "en_GB", "ru_RU", "en_US@hours=h23", "en_GB@hours=h12"])
    func headerDateBeginsWithTheListDate(identifier: String) {
        #expect(Self.dateTime(identifier).hasPrefix(Self.monthDay(identifier)))
    }

    /// The list row for a session from an earlier day.
    @MainActor
    @Test(arguments: ["en_US", "en_GB", "ru_RU"])
    func listRowUsesTheMonthDayDisplay(identifier: String) {
        let calendar = Self.calendar(identifier)
        let row = JobsViewModel.relativeTimestampText(
            for: Self.sample,
            referenceDate: Self.sample.addingTimeInterval(3 * 86_400),
            calendar: calendar,
            locale: Locale(identifier: identifier)
        )
        #expect(row == Self.monthDay(identifier))
    }

    // MARK: - Call sites

    @Test(.tags(.sourceLint))
    func headerAndDefaultTitlesUseTheDisplayDates() throws {
        let header = try readSource("../UI/TranscriptDetailView.swift")
        let appState = try readSource("../ViewModels/AppState.swift")
        let recording = try readSource("../Services/Audio/Capture/RecordingService.swift")

        #expect(!header.contains(".dateFormat ="))
        #expect(header.contains("TimeFormatter.displayDateTime(session.createdAt)"))
        // The pending title and the header must agree, so both go through the same function.
        #expect(appState.contains("TimeFormatter.displayDateTime(referenceDate)"))
        #expect(!recording.contains("\"MMM dd, HH:mm\""))
        #expect(recording.contains("TimeFormatter.displayMonthDayTime(createdAt)"))
    }

    @MainActor
    @Test
    func trimLabelShowsHours() throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let session = RecordingSession(createdAt: .now, duration: 4_500, micAudioURL: "/tmp/mic.wav", title: "Test", status: .done)
        let viewModel = TrimEditorViewModel(session: session, audioPlayer: AudioPlayerViewModel(), context: ModelContext(container))

        #expect(viewModel.keepRangeLabel == "Keep: 0:00 → 1:15:00")
    }

    @Test(.tags(.sourceLint))
    func onScreenDurationsUseTheDisplayFormat() throws {
        let timer = try readSource("../UI/ActiveRecordingDetailView.swift")
        let player = try readSource("../UI/AudioPlayerBar.swift")
        let menu = try readSource("../AppDelegate.swift")
        let trim = try readSource("../ViewModels/TrimEditorViewModel.swift")

        #expect(!timer.contains("private func durationText"))
        #expect(timer.contains("TimeFormatter.displayFormat(seconds: Float(currentDuration))"))
        #expect(!player.contains("private func formatTime"))
        #expect(player.contains("TimeFormatter.displayFormat(seconds: Float(viewModel.currentTime))"))
        #expect(player.contains("TimeFormatter.displayFormat(seconds: Float(viewModel.duration))"))
        #expect(!menu.contains("private func menuDuration"))
        #expect(menu.contains("TimeFormatter.displayFormat(seconds: Float(duration))"))
        #expect(!trim.contains("private func formatTime"))
        #expect(trim.contains("TimeFormatter.displayFormat(seconds: Float(trimPosition))"))
    }

    private func readSource(_ relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent(relativePathFromTests),
            encoding: .utf8
        )
    }
}
