import Foundation
import Observation
import Testing
@testable import Scriberman

@MainActor
struct MenuBarSettingsTests {
    @Test
    func testDefaults() {
        let (settings, cleanup) = makeSubject()
        defer { cleanup() }

        #expect(settings.isInTrayMode == false)
        #expect(settings.closeAction == .ask)
        #expect(settings.hasShownFirstTimeTrayAlert == false)
        #expect(settings.lastUsedMicUID == nil)
        #expect(settings.lastUsedAppBundleID == nil)
    }

    @Test
    func testPersistenceRoundTrip() {
        let suiteName = "MenuBarSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let initialSettings = MenuBarSettings(userDefaults: userDefaults)
        initialSettings.isInTrayMode = true
        initialSettings.closeAction = .tray
        initialSettings.hasShownFirstTimeTrayAlert = true
        initialSettings.lastUsedMicUID = "mic-uid-1"
        initialSettings.lastUsedAppBundleID = "com.apple.Music"

        let restoredSettings = MenuBarSettings(userDefaults: userDefaults)

        #expect(restoredSettings.isInTrayMode)
        #expect(restoredSettings.closeAction == .tray)
        #expect(restoredSettings.hasShownFirstTimeTrayAlert)
        #expect(restoredSettings.lastUsedMicUID == "mic-uid-1")
        #expect(restoredSettings.lastUsedAppBundleID == "com.apple.Music")
    }

    @Test
    func isInTrayModeNotifiesObservers() async {
        let (settings, cleanup) = makeSubject()
        defer { cleanup() }

        await confirmation("Preference change is observed") { changed in
            withObservationTracking {
                _ = settings.isInTrayMode
            } onChange: {
                changed()
            }
            settings.isInTrayMode = true
        }
        #expect(settings.isInTrayMode == true)
    }

    @Test
    func closeActionNotifiesObservers() async {
        let (settings, cleanup) = makeSubject()
        defer { cleanup() }

        await confirmation("Preference change is observed") { changed in
            withObservationTracking {
                _ = settings.closeAction
            } onChange: {
                changed()
            }
            settings.closeAction = .tray
        }
        #expect(settings.closeAction == .tray)
    }

    @Test
    func hasShownFirstTimeTrayAlertNotifiesObservers() async {
        let (settings, cleanup) = makeSubject()
        defer { cleanup() }

        await confirmation("Preference change is observed") { changed in
            withObservationTracking {
                _ = settings.hasShownFirstTimeTrayAlert
            } onChange: {
                changed()
            }
            settings.hasShownFirstTimeTrayAlert = true
        }
        #expect(settings.hasShownFirstTimeTrayAlert == true)
    }

    @Test
    func lastUsedMicUIDNotifiesObservers() async {
        let (settings, cleanup) = makeSubject()
        defer { cleanup() }

        await confirmation("Preference change is observed") { changed in
            withObservationTracking {
                _ = settings.lastUsedMicUID
            } onChange: {
                changed()
            }
            settings.lastUsedMicUID = "mic"
        }
        #expect(settings.lastUsedMicUID == "mic")
    }

    @Test
    func lastUsedAppBundleIDNotifiesObservers() async {
        let (settings, cleanup) = makeSubject()
        defer { cleanup() }

        await confirmation("Preference change is observed") { changed in
            withObservationTracking {
                _ = settings.lastUsedAppBundleID
            } onChange: {
                changed()
            }
            settings.lastUsedAppBundleID = "com.apple.Music"
        }
        #expect(settings.lastUsedAppBundleID == "com.apple.Music")
    }

    @Test
    func invalidCloseActionFallsBackToAsk() {
        let suiteName = "MenuBarSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set("invalid", forKey: "menuBar.closeAction")

        #expect(MenuBarSettings(userDefaults: userDefaults).closeAction == .ask)
    }

    @Test
    func clearedDevicePreferencesStayCleared() {
        let suiteName = "MenuBarSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = MenuBarSettings(userDefaults: userDefaults)
        settings.lastUsedMicUID = "mic"
        settings.lastUsedAppBundleID = "com.apple.Music"
        settings.lastUsedMicUID = nil
        settings.lastUsedAppBundleID = nil

        let restored = MenuBarSettings(userDefaults: userDefaults)
        #expect(restored.lastUsedMicUID == nil)
        #expect(restored.lastUsedAppBundleID == nil)
    }

    private func makeSubject() -> (MenuBarSettings, () -> Void) {
        let suiteName = "MenuBarSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)

        let cleanup = {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        return (MenuBarSettings(userDefaults: userDefaults), cleanup)
    }
}
