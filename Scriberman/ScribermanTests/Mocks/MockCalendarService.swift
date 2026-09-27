import Foundation
@testable import Scriberman

/// In-memory calendar service. Handlers let a test hold an access request or query open.
final class MockCalendarService: CalendarServiceProtocol, @unchecked Sendable {
    struct State {
        var status: CalendarAuthorizationStatus = .notDetermined
        var statusAfterRequest: CalendarAuthorizationStatus = .fullAccess
        var calendars: [CalendarSnapshot] = []
        var events: [CalendarEventSnapshot] = []
        var calendarsError: Error?
        var eventsError: Error?
        var accessRequestCount = 0
        var calendarsCallCount = 0
        var eventQueries: [(calendarIDs: Set<String>, start: Date, end: Date)] = []
        var accessGate: TestGate?
        var eventsGate: TestGate?
        var storeContinuations: [AsyncStream<Void>.Continuation] = []
    }

    private let lock = NSLock()
    private var state = State()

    init(status: CalendarAuthorizationStatus = .notDetermined) {
        state.status = status
    }

    private func withLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    func update(_ body: (inout State) -> Void) {
        withLock(body)
    }

    func read<T>(_ body: (State) -> T) -> T {
        withLock { body($0) }
    }

    var eventQueryCount: Int { read(\.eventQueries.count) }

    func authorizationStatus() -> CalendarAuthorizationStatus {
        read(\.status)
    }

    func requestAccess() async throws -> Bool {
        let gate = withLock { state -> TestGate? in
            state.accessRequestCount += 1
            return state.accessGate
        }
        await gate?.wait()
        return withLock { state in
            state.status = state.statusAfterRequest
            return state.status == .fullAccess
        }
    }

    func calendars() async throws -> [CalendarSnapshot] {
        try withLock { state in
            state.calendarsCallCount += 1
            if let error = state.calendarsError { throw error }
            return state.calendars
        }
    }

    func events(calendarIDs: Set<String>, from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        let gate = withLock { state -> TestGate? in
            state.eventQueries.append((calendarIDs, start, end))
            return state.eventsGate
        }
        await gate?.wait()
        return try withLock { state in
            if let error = state.eventsError { throw error }
            return state.events.filter { calendarIDs.contains($0.calendarID) && $0.end > start && $0.start < end }
        }
    }

    func storeChanges() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        withLock { $0.storeContinuations.append(continuation) }
        return stream
    }

    func simulateStoreChange() {
        read(\.storeContinuations).forEach { $0.yield() }
    }
}

/// A one-shot latch: `wait()` suspends until `open()`.
final class TestGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func wait() async {
        for await _ in stream { return }
    }

    func open() {
        continuation.yield()
        continuation.finish()
    }
}

struct MockCalendarError: Error {}

extension CalendarEventSnapshot {
    static func fixture(
        calendarID: String = "work",
        itemID: String = "item-1",
        title: String = "Design review",
        start: Date,
        duration: TimeInterval = 30 * 60,
        isAllDay: Bool = false,
        status: Status = .confirmed,
        selfResponse: SelfResponse = .accepted,
        url: URL? = URL(string: "https://zoom.us/j/123456789"),
        location: String? = nil,
        notes: String? = nil
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            calendarID: calendarID,
            calendarItemID: itemID,
            title: title,
            start: start,
            end: start.addingTimeInterval(duration),
            isAllDay: isAllDay,
            status: status,
            selfResponse: selfResponse,
            url: url,
            location: location,
            notes: notes
        )
    }
}
