import Foundation

/// Read-only access to calendars connected to macOS. Implementations return snapshots only; no
/// EventKit object crosses this boundary.
protocol CalendarServiceProtocol: Sendable {
    func authorizationStatus() -> CalendarAuthorizationStatus
    /// Asks for full calendar access. Returns whether it was granted.
    func requestAccess() async throws -> Bool
    func calendars() async throws -> [CalendarSnapshot]
    /// Occurrences overlapping `start..<end` in the given calendars. Identifiers that no longer
    /// match a calendar are ignored.
    func events(calendarIDs: Set<String>, from start: Date, to end: Date) async throws -> [CalendarEventSnapshot]
    /// Yields when the calendar database changes. Previously fetched data is then stale.
    func storeChanges() -> AsyncStream<Void>
}
