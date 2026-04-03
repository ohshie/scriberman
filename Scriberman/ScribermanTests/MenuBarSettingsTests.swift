import Foundation
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
