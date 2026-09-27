import EventKit
import Foundation

/// EventKit adapter. The store and every EventKit object stay inside this actor; callers receive
/// snapshots. Nothing here writes to a calendar.
actor EventKitCalendarService: CalendarServiceProtocol {
    private let store = EKEventStore()

    nonisolated func authorizationStatus() -> CalendarAuthorizationStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .fullAccess
        case .restricted: .restricted
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func calendars() async throws -> [CalendarSnapshot] {
        guard authorizationStatus() == .fullAccess else { throw CalendarServiceError.notAuthorized }
        return store.calendars(for: .event).map { calendar in
            CalendarSnapshot(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: calendar.source?.title ?? ""
            )
        }
    }

    func events(calendarIDs: Set<String>, from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        guard authorizationStatus() == .fullAccess else { throw CalendarServiceError.notAuthorized }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // A nil or empty calendar list in the predicate means every calendar.
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap(Self.snapshot)
    }

    nonisolated func storeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    continuation.yield()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot? {
        guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate else {
            return nil
        }
        let status: CalendarEventSnapshot.Status = switch event.status {
        case .confirmed: .confirmed
        case .tentative: .tentative
        case .canceled: .cancelled
        case .none: .none
        @unknown default: .none
        }
        let selfResponse: CalendarEventSnapshot.SelfResponse =
            switch event.attendees?.first(where: \.isCurrentUser)?.participantStatus {
            case .accepted: .accepted
            case .tentative: .tentative
            case .declined: .declined
            default: .unknown
            }
        return CalendarEventSnapshot(
            calendarID: calendar.calendarIdentifier,
            calendarItemID: event.calendarItemIdentifier,
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            status: status,
            selfResponse: selfResponse,
            url: event.url,
            location: event.location,
            notes: event.notes
        )
    }
}

enum CalendarServiceError: Error {
    case notAuthorized
}
