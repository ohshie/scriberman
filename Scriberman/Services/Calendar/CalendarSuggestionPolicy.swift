import Foundation

/// A meeting that can be offered right now.
struct CalendarMeetingSuggestion: Identifiable, Hashable, Sendable {
    let occurrenceID: CalendarOccurrenceID
    let title: String
    let start: Date
    /// When the suggestion window closes.
    let windowEnd: Date

    var id: CalendarOccurrenceID { occurrenceID }
}

/// Pure rules for which events become suggestions and when. Time is always passed in.
enum CalendarSuggestionPolicy {
    static let leadTime: TimeInterval = 2 * 60
    static let graceTime: TimeInterval = 5 * 60
    static let lookAhead: TimeInterval = 24 * 60 * 60

    /// The range queried from EventKit.
    static func queryRange(now: Date) -> (start: Date, end: Date) {
        (now.addingTimeInterval(-graceTime), now.addingTimeInterval(lookAhead))
    }

    /// Whether an event can ever be suggested, regardless of time or handled state.
    static func qualifies(_ event: CalendarEventSnapshot, selectedCalendarIDs: Set<String>) -> Bool {
        selectedCalendarIDs.contains(event.calendarID)
            && !event.isAllDay
            && event.status != .cancelled
            && event.selfResponse != .declined
            && MeetingLinkMatcher.service(for: event) != nil
    }

    static func windowStart(of event: CalendarEventSnapshot) -> Date {
        event.start.addingTimeInterval(-leadTime)
    }

    /// The earlier of five minutes after the start and the scheduled end.
    static func windowEnd(of event: CalendarEventSnapshot) -> Date {
        min(event.start.addingTimeInterval(graceTime), event.end)
    }

    /// `start - 2 min <= now < min(start + 5 min, end)`.
    static func isInWindow(_ event: CalendarEventSnapshot, now: Date) -> Bool {
        windowStart(of: event) <= now && now < windowEnd(of: event)
    }

    /// Qualifying, in-window events that were not handled, ordered by start then identity.
    static func suggestions(
        from events: [CalendarEventSnapshot],
        selectedCalendarIDs: Set<String>,
        now: Date,
        isHandled: (CalendarOccurrenceID) -> Bool
    ) -> [CalendarMeetingSuggestion] {
        var seen = Set<CalendarOccurrenceID>()
        return events
            .filter { qualifies($0, selectedCalendarIDs: selectedCalendarIDs) && isInWindow($0, now: now) }
            .filter { !isHandled($0.occurrenceID) && seen.insert($0.occurrenceID).inserted }
            .map {
                CalendarMeetingSuggestion(
                    occurrenceID: $0.occurrenceID,
                    title: $0.title,
                    start: $0.start,
                    windowEnd: windowEnd(of: $0)
                )
            }
            .sorted { $0.occurrenceID < $1.occurrenceID }
    }

    /// The next instant after `now` at which some qualifying event enters or leaves its window.
    static func nextBoundary(
        after now: Date,
        events: [CalendarEventSnapshot],
        selectedCalendarIDs: Set<String>
    ) -> Date? {
        events
            .filter { qualifies($0, selectedCalendarIDs: selectedCalendarIDs) }
            .flatMap { [windowStart(of: $0), windowEnd(of: $0)] }
            .filter { $0 > now }
            .min()
    }
}
