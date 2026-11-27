import Foundation

/// Runs at launch when the service container creates the audio settings.
@MainActor
final class AppAudioSettings {
    init(userDefaults: UserDefaults = .standard) {
        Self.migrateRemovedSettings(in: userDefaults)
    }

    static func migrateRemovedSettings(in store: UserDefaults) {
        let migration = "audio.removedVoiceProcessingSetting"
        guard !store.bool(forKey: migration) else { return }
        store.removeObject(forKey: "audio.voiceProcessingEnabled")
        store.removeObject(forKey: "AudioSync.unifiedCaptureEnabled")
        store.set(true, forKey: migration)
    }
}
