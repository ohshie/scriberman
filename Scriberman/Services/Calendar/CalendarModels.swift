import CryptoKit
import Foundation

/// Calendar access as far as suggestions are concerned. Write-only access cannot read events, so
/// it counts as denied.
enum CalendarAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
    case restricted
}

/// An immutable copy of a calendar, safe to hand across isolation boundaries.
struct CalendarSnapshot: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// The account the calendar belongs to, such as "iCloud" or a Google address.
    let sourceTitle: String
}

/// An immutable copy of one event occurrence. Nothing here is persisted.
struct CalendarEventSnapshot: Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case none
        case confirmed
        case tentative
        case cancelled
    }

    /// The current user's response, when the event lists them as an attendee.
    enum SelfResponse: Hashable, Sendable {
        case unknown
        case accepted
        case tentative
        case declined
    }

    let calendarID: String
    let calendarItemID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let status: Status
    let selfResponse: SelfResponse
    let url: URL?
    let location: String?
    let notes: String?

    var occurrenceID: CalendarOccurrenceID {
        CalendarOccurrenceID(calendarID: calendarID, calendarItemID: calendarItemID, start: start)
    }
}

/// Identifies one scheduled occurrence. The start instant separates instances of a recurring
/// series, and a moved occurrence gets a new identity.
struct CalendarOccurrenceID: Hashable, Comparable, Sendable {
    let calendarID: String
    let calendarItemID: String
    let start: Date

    /// A SHA-256 digest of the identity, so calendar identifiers are not written to disk.
    var persistentKey: String {
        let raw = "\(calendarID)\u{1F}\(calendarItemID)\u{1F}\(start.timeIntervalSince1970)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func < (lhs: CalendarOccurrenceID, rhs: CalendarOccurrenceID) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.calendarID != rhs.calendarID { return lhs.calendarID < rhs.calendarID }
        return lhs.calendarItemID < rhs.calendarItemID
    }
}
