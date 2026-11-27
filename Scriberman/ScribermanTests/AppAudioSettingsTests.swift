import Foundation
import Testing
@testable import Scriberman

@MainActor
struct AppAudioSettingsTests {
    @Test(arguments: [false, true])
    func launchDeletesRemovedSettingsOnce(oldValue: Bool) {
        let suite = "AppAudioSettingsTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        store.set(oldValue, forKey: "audio.voiceProcessingEnabled")
        store.set(false, forKey: "AudioSync.unifiedCaptureEnabled")
        _ = AppAudioSettings(userDefaults: store)
        #expect(store.object(forKey: "audio.voiceProcessingEnabled") == nil)
        #expect(store.object(forKey: "AudioSync.unifiedCaptureEnabled") == nil)
        store.set(true, forKey: "audio.voiceProcessingEnabled")
        _ = AppAudioSettings(userDefaults: store)
        #expect(store.bool(forKey: "audio.voiceProcessingEnabled"))
    }
}
