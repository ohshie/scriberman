import Foundation
import Observation

@MainActor
@Observable
final class AppAudioSettings {
    private enum Key {
        static let voiceProcessingEnabled = "audio.voiceProcessingEnabled"
    }

    private let userDefaults: UserDefaults

    var voiceProcessingEnabled: Bool {
        get { userDefaults.bool(forKey: Key.voiceProcessingEnabled) }
        set { userDefaults.set(newValue, forKey: Key.voiceProcessingEnabled) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func resetToDefaults() {
        voiceProcessingEnabled = false
    }
}
