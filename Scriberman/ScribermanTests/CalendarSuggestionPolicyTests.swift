import Foundation
import Testing
@testable import Scriberman

struct CalendarSuggestionPolicyTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let selected: Set<String> = ["work"]

    private func suggestions(_ events: [CalendarEventSnapshot], at now: Date, handled: Set<CalendarOccurrenceID> = []) -> [CalendarMeetingSuggestion] {
        CalendarSuggestionPolicy.suggestions(from: events, selectedCalendarIDs: selected, now: now) { handled.contains($0) }
    }

    // MARK: - Filtering

    @Test("All-day, cancelled, self-declined and unselected events are excluded")
    func exclusions() {
        let events: [CalendarEventSnapshot] = [
            .fixture(itemID: "all-day", start: start, isAllDay: true),
            .fixture(itemID: "cancelled", start: start, status: .cancelled),
            .fixture(itemID: "declined", start: start, selfResponse: .declined),
            .fixture(calendarID: "home", itemID: "unselected", start: start),
            .fixture(itemID: "no-link", start: start, url: nil, notes: "Zoom"),
        ]
        #expect(suggestions(events, at: start).isEmpty)
    }

    @Test("Unknown and tentative attendee responses are kept")
    func unknownResponseIncluded() {
        let events: [CalendarEventSnapshot] = [
            .fixture(itemID: "unknown", start: start, selfResponse: .unknown),
            .fixture(itemID: "tentative", start: start, status: .tentative, selfResponse: .tentative),
        ]
        #expect(suggestions(events, at: start).map(\.occurrenceID.calendarItemID) == ["tentative", "unknown"])
    }

    @Test("Recurring instances have separate identities")
    func recurringInstancesSeparate() {
        let first = CalendarEventSnapshot.fixture(itemID: "series", start: start)
        let second = CalendarEventSnapshot.fixture(itemID: "series", start: start.addingTimeInterval(7 * 86_400))
        #expect(first.occurrenceID != second.occurrenceID)
        #expect(first.occurrenceID.persistentKey != second.occurrenceID.persistentKey)

        // Handling the first does not suppress the second.
        let later = suggestions([second], at: second.start, handled: [first.occurrenceID])
        #expect(later.map(\.occurrenceID) == [second.occurrenceID])
    }

    @Test("A rescheduled occurrence gets a new identity and is eligible at its new time")
    func rescheduledOccurrence() {
        let original = CalendarEventSnapshot.fixture(itemID: "moved", start: start)
        let moved = CalendarEventSnapshot.fixture(itemID: "moved", start: start.addingTimeInterval(3_600))
        let result = suggestions([moved], at: moved.start, handled: [original.occurrenceID])
        #expect(result.map(\.occurrenceID) == [moved.occurrenceID])
        #expect(suggestions([moved], at: start).isEmpty)
    }

    @Test("Duplicate copies in separate calendars stay separate")
    func duplicatesAcrossCalendars() {
        let events: [CalendarEventSnapshot] = [
            .fixture(calendarID: "work", itemID: "a", start: start),
            .fixture(calendarID: "shared", itemID: "b", start: start),
        ]
        let result = CalendarSuggestionPolicy.suggestions(
            from: events,
            selectedCalendarIDs: ["work", "shared"],
            now: start,
            isHandled: { _ in false }
        )
        #expect(result.count == 2)
    }

    // MARK: - Window

    @Test("Window opens exactly two minutes before the start")
    func leadBoundary() {
        let event = CalendarEventSnapshot.fixture(start: start)
        #expect(suggestions([event], at: start.addingTimeInterval(-120.001)).isEmpty)
        #expect(suggestions([event], at: start.addingTimeInterval(-120)).count == 1)
    }

    @Test("Window closes exactly five minutes after the start")
    func graceBoundary() {
        let event = CalendarEventSnapshot.fixture(start: start)
        #expect(suggestions([event], at: start.addingTimeInterval(299.999)).count == 1)
        #expect(suggestions([event], at: start.addingTimeInterval(300)).isEmpty)
    }

    @Test("A meeting shorter than the grace period expires at its scheduled end")
    func endBoundary() {
        let event = CalendarEventSnapshot.fixture(start: start, duration: 180)
        #expect(suggestions([event], at: start.addingTimeInterval(179.999)).count == 1)
        #expect(suggestions([event], at: start.addingTimeInterval(180)).isEmpty)
        #expect(suggestions([event], at: start).first?.windowEnd == start.addingTimeInterval(180))
    }

    @Test("Overlapping meetings are ordered by start, then identity")
    func stableOrdering() {
        let events: [CalendarEventSnapshot] = [
            .fixture(itemID: "c", start: start.addingTimeInterval(60)),
            .fixture(itemID: "b", start: start),
            .fixture(itemID: "a", start: start),
        ]
        let ids = suggestions(events, at: start.addingTimeInterval(60)).map(\.occurrenceID.calendarItemID)
        #expect(ids == ["a", "b", "c"])
    }

    @Test("Query range is five minutes back through 24 hours ahead")
    func queryRange() {
        let range = CalendarSuggestionPolicy.queryRange(now: start)
        #expect(range.start == start.addingTimeInterval(-300))
        #expect(range.end == start.addingTimeInterval(86_400))
    }

    @Test("Next boundary is the nearest window start or end")
    func nextBoundary() {
        let events: [CalendarEventSnapshot] = [
            .fixture(itemID: "now", start: start),
            .fixture(itemID: "later", start: start.addingTimeInterval(3_600)),
        ]
        #expect(CalendarSuggestionPolicy.nextBoundary(after: start, events: events, selectedCalendarIDs: selected)
                == start.addingTimeInterval(300))
        #expect(CalendarSuggestionPolicy.nextBoundary(after: start.addingTimeInterval(300), events: events, selectedCalendarIDs: selected)
                == start.addingTimeInterval(3_480))
    }
}
