import Foundation

enum TimeFormatter {
    static func format(seconds: Float) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }

        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    /// The form shown in the interface: `m:ss`, or `h:mm:ss` past the hour.
    ///
    /// Separate from `format` because the two have different masters. Exported markdown specifies
    /// zero-padded `MM:SS`, and a file someone parses should not change shape because a recording
    /// was under ten minutes. On screen the padding is worse than useless: `01:35` is how an hour
    /// and thirty-five minutes is written, so a 95-second recording reads as a meeting.
    ///
    /// Truncating, like `format`: a 94.6-second recording is 1:34 and has not reached 1:35 — which
    /// is also what its player counts up to.
    static func displayFormat(seconds: Float) -> String {
        guard seconds.isFinite else {
            return displayFormat(seconds: 0)
        }

        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }

        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func formatWithMilliseconds(seconds: Float) -> String {
        let totalMilliseconds = max(0, Int((Double(seconds) * 1_000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let remainingSeconds = (totalMilliseconds % 60_000) / 1_000
        let milliseconds = totalMilliseconds % 1_000

        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, remainingSeconds, milliseconds)
    }

    // MARK: - Dates

    /// Date and time of a session: the detail header and the default session title.
    ///
    /// System format styles, so the order of day and month and the 12- or 24-hour clock follow the
    /// user's region settings. File names keep their fixed patterns; this is only for the screen.
    static func displayDateTime(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }

    /// Day and month of a session in the list, in the same order as `displayDateTime`.
    static func displayMonthDay(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
    }

    /// Day, month and time without the year: the title of a finished recording.
    static func displayMonthDayTime(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day().hour().minute())
    }
}
