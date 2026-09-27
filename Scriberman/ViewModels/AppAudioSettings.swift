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
        didSet { userDefaults.set(voiceProcessingEnabled, forKey: Key.voiceProcessingEnabled) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        voiceProcessingEnabled = userDefaults.bool(forKey: Key.voiceProcessingEnabled)
    }

    func resetToDefaults() {
        voiceProcessingEnabled = false
    }
}
