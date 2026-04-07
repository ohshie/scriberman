import Foundation
import Testing
@testable import Scriberman

@MainActor
struct AppAudioSettingsTests {
    @Test
    func testDefaults() {
        let (settings, cleanup) = makeSubject()
        defer { cleanup() }

        #expect(settings.voiceProcessingEnabled == false)
    }

    @Test
    func testPersistenceRoundTrip() {
        let suiteName = "AppAudioSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let initialSettings = AppAudioSettings(userDefaults: userDefaults)
        initialSettings.voiceProcessingEnabled = true

        let restoredSettings = AppAudioSettings(userDefaults: userDefaults)
        #expect(restoredSettings.voiceProcessingEnabled == true)
    }

    private func makeSubject() -> (AppAudioSettings, () -> Void) {
        let suiteName = "AppAudioSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)

        let cleanup = {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        return (AppAudioSettings(userDefaults: userDefaults), cleanup)
    }
}
