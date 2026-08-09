import Foundation
import Testing
@testable import Scriberman

@MainActor
struct IdlePromptPreferencesTests {
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "IdlePromptPreferencesTests-\(UUID().uuidString)")!
        return suite
    }

    @Test("Fresh install uses the shipped defaults")
    func defaults() {
        let preferences = IdlePromptPreferences(userDefaults: makeDefaults())
        #expect(preferences.isEnabled)
        #expect(preferences.watchAppAudio)
        #expect(!preferences.watchMicAudio)
        #expect(!preferences.watchUserInput)
        #expect(preferences.requiresAllSourcesIdle)
        #expect(preferences.idleThresholdMinutes == 5)
        #expect(!preferences.autoStopEnabled)
        #expect(preferences.autoStopDelayMinutes == 5)
    }

    @Test("Values persist in the backing store")
    func valuesPersist() {
        let defaults = makeDefaults()
        let first = IdlePromptPreferences(userDefaults: defaults)
        first.isEnabled = false
        first.watchMicAudio = true
        first.watchUserInput = true
        first.requiresAllSourcesIdle = false
        first.idleThresholdMinutes = 20
        first.autoStopEnabled = true
        first.autoStopDelayMinutes = 15

        // A second instance over the same store models an app relaunch.
        let second = IdlePromptPreferences(userDefaults: defaults)
        #expect(!second.isEnabled)
        #expect(second.watchMicAudio)
        #expect(second.watchUserInput)
        #expect(!second.requiresAllSourcesIdle)
        #expect(second.idleThresholdMinutes == 20)
        #expect(second.autoStopEnabled)
        #expect(second.autoStopDelayMinutes == 15)
    }

    @Test("Turning a source off persists as false rather than reverting to its default")
    func falseIsDistinctFromUnset() {
        let defaults = makeDefaults()
        let preferences = IdlePromptPreferences(userDefaults: defaults)
        preferences.watchAppAudio = false
        #expect(!IdlePromptPreferences(userDefaults: defaults).watchAppAudio)
    }

    @Test("Non-positive minute values fall back to the defaults")
    func rejectsNonPositiveMinutes() {
        let defaults = makeDefaults()
        let preferences = IdlePromptPreferences(userDefaults: defaults)
        preferences.idleThresholdMinutes = 0
        preferences.autoStopDelayMinutes = -5
        #expect(preferences.idleThresholdMinutes >= 1)
        #expect(preferences.autoStopDelayMinutes >= 1)
    }

    @Test("Watched source count drives the combination control")
    func watchedSourceCount() {
        let preferences = IdlePromptPreferences(userDefaults: makeDefaults())
        #expect(preferences.watchedSourceCount == 1)
        preferences.watchMicAudio = true
        #expect(preferences.watchedSourceCount == 2)
        preferences.watchAppAudio = false
        preferences.watchMicAudio = false
        #expect(preferences.watchedSourceCount == 0)
    }

    @Test("Snapshot converts minutes into the evaluator's seconds")
    func snapshotConvertsUnits() {
        let preferences = IdlePromptPreferences(userDefaults: makeDefaults())
        preferences.idleThresholdMinutes = 10
        preferences.autoStopDelayMinutes = 3

        let settings = preferences.settings
        #expect(settings.idleThreshold == 600)
        #expect(settings.autoStopDelay == 180)
        #expect(settings.watchAppAudio)
        #expect(settings.requiresAllSourcesIdle)
    }

    @Test("Reset restores the shipped defaults")
    func resetRestoresDefaults() {
        let preferences = IdlePromptPreferences(userDefaults: makeDefaults())
        preferences.watchUserInput = true
        preferences.idleThresholdMinutes = 45
        preferences.autoStopEnabled = true

        preferences.resetToDefaults()

        #expect(!preferences.watchUserInput)
        #expect(preferences.idleThresholdMinutes == 5)
        #expect(!preferences.autoStopEnabled)
    }
}
