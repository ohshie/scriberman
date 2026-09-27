import Foundation
import Observation

/// Persisted state for calendar meeting suggestions.
///
/// Absent keys mean: feature off, invitation never shown, calendar selection not yet seeded, and
/// nothing handled. Stored properties (not computed accessors) because `@Observable` only tracks
/// stored ones.
@MainActor
@Observable
final class CalendarSuggestionPreferences {
    private enum Key {
        static let isEnabled = "calendarSuggestions.isEnabled"
        static let invitationShown = "calendarSuggestions.invitationShown"
        static let selectedCalendarIDs = "calendarSuggestions.selectedCalendarIDs"
        static let isSelectionInitialized = "calendarSuggestions.isSelectionInitialized"
        static let handledOccurrences = "calendarSuggestions.handledOccurrences"
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    var invitationShown: Bool {
        didSet { userDefaults.set(invitationShown, forKey: Key.invitationShown) }
    }

    private(set) var selectedCalendarIDs: Set<String> {
        didSet { userDefaults.set(selectedCalendarIDs.sorted(), forKey: Key.selectedCalendarIDs) }
    }

    /// True once the first successful calendar enumeration has seeded the selection. An empty
    /// selection after that is the user's choice and is never reseeded.
    private(set) var isSelectionInitialized: Bool {
        didSet { userDefaults.set(isSelectionInitialized, forKey: Key.isSelectionInitialized) }
    }

    /// Hashed occurrence identity → end of that occurrence's suggestion window.
    @ObservationIgnored private var handledOccurrences: [String: Date] {
        didSet {
            userDefaults.set(
                handledOccurrences.mapValues(\.timeIntervalSince1970),
                forKey: Key.handledOccurrences
            )
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.object(forKey: Key.isEnabled) as? Bool ?? false
        invitationShown = userDefaults.object(forKey: Key.invitationShown) as? Bool ?? false
        selectedCalendarIDs = Set(userDefaults.stringArray(forKey: Key.selectedCalendarIDs) ?? [])
        isSelectionInitialized = userDefaults.object(forKey: Key.isSelectionInitialized) as? Bool ?? false
        let stored = userDefaults.dictionary(forKey: Key.handledOccurrences) as? [String: Double] ?? [:]
        handledOccurrences = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Selects every calendar from the first successful enumeration. Later calls do nothing, so
    /// calendars added afterwards stay unselected.
    func seedSelectionIfNeeded(availableCalendarIDs: Set<String>) {
        guard !isSelectionInitialized else { return }
        selectedCalendarIDs = availableCalendarIDs
        isSelectionInitialized = true
    }

    func setCalendar(_ calendarID: String, selected: Bool) {
        if selected {
            selectedCalendarIDs.insert(calendarID)
        } else {
            selectedCalendarIDs.remove(calendarID)
        }
        isSelectionInitialized = true
    }

    func isHandled(_ occurrence: CalendarOccurrenceID) -> Bool {
        handledOccurrences[occurrence.persistentKey] != nil
    }

    func markHandled(_ occurrence: CalendarOccurrenceID, expiresAt: Date) {
        handledOccurrences[occurrence.persistentKey] = expiresAt
    }

    /// Drops handled entries whose suggestion window has ended.
    func pruneHandled(now: Date) {
        let kept = handledOccurrences.filter { $0.value > now }
        if kept.count != handledOccurrences.count {
            handledOccurrences = kept
        }
    }

    var handledOccurrenceCount: Int {
        handledOccurrences.count
    }
}
