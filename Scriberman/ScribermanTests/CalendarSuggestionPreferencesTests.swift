import Foundation
import Testing
@testable import Scriberman

@MainActor
struct CalendarSuggestionPreferencesTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CalendarSuggestionPreferencesTests-\(UUID().uuidString)")!
    }

    private let occurrence = CalendarOccurrenceID(
        calendarID: "work",
        calendarItemID: "item-1",
        start: Date(timeIntervalSince1970: 1_000_000)
    )

    @Test("Absent keys mean off, invitation not shown, selection not initialized")
    func absentKeys() {
        let preferences = CalendarSuggestionPreferences(userDefaults: makeDefaults())
        #expect(!preferences.isEnabled)
        #expect(!preferences.invitationShown)
        #expect(!preferences.isSelectionInitialized)
        #expect(preferences.selectedCalendarIDs.isEmpty)
        #expect(preferences.handledOccurrenceCount == 0)
    }

    @Test("Values persist across a relaunch")
    func relaunchPersistence() {
        let defaults = makeDefaults()
        let first = CalendarSuggestionPreferences(userDefaults: defaults)
        first.isEnabled = true
        first.invitationShown = true
        first.seedSelectionIfNeeded(availableCalendarIDs: ["work", "home"])
        first.markHandled(occurrence, expiresAt: Date(timeIntervalSince1970: 2_000_000))

        let second = CalendarSuggestionPreferences(userDefaults: defaults)
        #expect(second.isEnabled)
        #expect(second.invitationShown)
        #expect(second.isSelectionInitialized)
        #expect(second.selectedCalendarIDs == ["work", "home"])
        #expect(second.isHandled(occurrence))
    }

    @Test("Seeding happens once; later calendars stay unselected")
    func seedsOnce() {
        let preferences = CalendarSuggestionPreferences(userDefaults: makeDefaults())
        preferences.seedSelectionIfNeeded(availableCalendarIDs: ["work"])
        preferences.seedSelectionIfNeeded(availableCalendarIDs: ["work", "new"])
        #expect(preferences.selectedCalendarIDs == ["work"])
    }

    @Test("A successful empty enumeration initializes an empty selection")
    func emptyEnumerationInitializes() {
        let preferences = CalendarSuggestionPreferences(userDefaults: makeDefaults())
        preferences.seedSelectionIfNeeded(availableCalendarIDs: [])
        preferences.seedSelectionIfNeeded(availableCalendarIDs: ["work"])
        #expect(preferences.isSelectionInitialized)
        #expect(preferences.selectedCalendarIDs.isEmpty)
    }

    @Test("An intentionally empty selection is not reseeded after relaunch")
    func intentionalEmptySelection() {
        let defaults = makeDefaults()
        let first = CalendarSuggestionPreferences(userDefaults: defaults)
        first.seedSelectionIfNeeded(availableCalendarIDs: ["work"])
        first.setCalendar("work", selected: false)

        let second = CalendarSuggestionPreferences(userDefaults: defaults)
        second.seedSelectionIfNeeded(availableCalendarIDs: ["work", "home"])
        #expect(second.selectedCalendarIDs.isEmpty)
    }

    @Test("Handled entries are pruned once their window has ended")
    func pruning() {
        let defaults = makeDefaults()
        let preferences = CalendarSuggestionPreferences(userDefaults: defaults)
        let later = CalendarOccurrenceID(calendarID: "work", calendarItemID: "item-2", start: Date(timeIntervalSince1970: 3_000_000))
        preferences.markHandled(occurrence, expiresAt: Date(timeIntervalSince1970: 1_000_300))
        preferences.markHandled(later, expiresAt: Date(timeIntervalSince1970: 3_000_300))

        preferences.pruneHandled(now: Date(timeIntervalSince1970: 1_000_300))

        #expect(!preferences.isHandled(occurrence))
        #expect(preferences.isHandled(later))
        #expect(!CalendarSuggestionPreferences(userDefaults: defaults).isHandled(occurrence))
    }

    @Test("Only hashed identities are stored")
    func storesHashes() {
        let defaults = makeDefaults()
        let preferences = CalendarSuggestionPreferences(userDefaults: defaults)
        preferences.markHandled(occurrence, expiresAt: Date(timeIntervalSince1970: 2_000_000))
        let stored = defaults.dictionary(forKey: "calendarSuggestions.handledOccurrences") ?? [:]
        #expect(stored.keys.count == 1)
        #expect(stored.keys.allSatisfy { !$0.contains("item-1") && $0.count == 64 })
    }
}
