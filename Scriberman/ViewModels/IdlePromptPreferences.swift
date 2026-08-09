import Foundation
import Observation

/// Persisted configuration for the idle session prompt.
///
/// Every value defaults to the shipped behaviour when unset, so a fresh install watches app
/// audio only, requires all watched sources to be idle, prompts after 5 minutes, and never
/// stops automatically.
@MainActor
@Observable
final class IdlePromptPreferences {
    private enum Key {
        static let isEnabled = "idlePrompt.isEnabled"
        static let watchAppAudio = "idlePrompt.watchAppAudio"
        static let watchMicAudio = "idlePrompt.watchMicAudio"
        static let watchUserInput = "idlePrompt.watchUserInput"
        static let requiresAllSourcesIdle = "idlePrompt.requiresAllSourcesIdle"
        static let idleThresholdMinutes = "idlePrompt.idleThresholdMinutes"
        static let autoStopEnabled = "idlePrompt.autoStopEnabled"
        static let autoStopDelayMinutes = "idlePrompt.autoStopDelayMinutes"
    }

    static let defaultIdleThresholdMinutes = 5
    static let defaultAutoStopDelayMinutes = 5
    /// Selectable durations for the two minute-valued settings.
    static let selectableMinutes = [1, 2, 5, 10, 15, 20, 30, 45, 60]

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isEnabled: Bool {
        get { bool(Key.isEnabled, default: true) }
        set { userDefaults.set(newValue, forKey: Key.isEnabled) }
    }

    var watchAppAudio: Bool {
        get { bool(Key.watchAppAudio, default: true) }
        set { userDefaults.set(newValue, forKey: Key.watchAppAudio) }
    }

    var watchMicAudio: Bool {
        get { bool(Key.watchMicAudio, default: false) }
        set { userDefaults.set(newValue, forKey: Key.watchMicAudio) }
    }

    var watchUserInput: Bool {
        get { bool(Key.watchUserInput, default: false) }
        set { userDefaults.set(newValue, forKey: Key.watchUserInput) }
    }

    var requiresAllSourcesIdle: Bool {
        get { bool(Key.requiresAllSourcesIdle, default: true) }
        set { userDefaults.set(newValue, forKey: Key.requiresAllSourcesIdle) }
    }

    var idleThresholdMinutes: Int {
        get { int(Key.idleThresholdMinutes, default: Self.defaultIdleThresholdMinutes) }
        set { userDefaults.set(max(1, newValue), forKey: Key.idleThresholdMinutes) }
    }

    var autoStopEnabled: Bool {
        get { bool(Key.autoStopEnabled, default: false) }
        set { userDefaults.set(newValue, forKey: Key.autoStopEnabled) }
    }

    var autoStopDelayMinutes: Int {
        get { int(Key.autoStopDelayMinutes, default: Self.defaultAutoStopDelayMinutes) }
        set { userDefaults.set(max(1, newValue), forKey: Key.autoStopDelayMinutes) }
    }

    /// Number of watched sources; the all/any rule is meaningless below two.
    var watchedSourceCount: Int {
        [watchAppAudio, watchMicAudio, watchUserInput].filter { $0 }.count
    }

    /// Snapshot for the evaluation layer.
    var settings: IdlePromptSettings {
        IdlePromptSettings(
            isEnabled: isEnabled,
            watchAppAudio: watchAppAudio,
            watchMicAudio: watchMicAudio,
            watchUserInput: watchUserInput,
            requiresAllSourcesIdle: requiresAllSourcesIdle,
            idleThreshold: TimeInterval(idleThresholdMinutes) * 60,
            autoStopEnabled: autoStopEnabled,
            autoStopDelay: TimeInterval(autoStopDelayMinutes) * 60
        )
    }

    func resetToDefaults() {
        isEnabled = true
        watchAppAudio = true
        watchMicAudio = false
        watchUserInput = false
        requiresAllSourcesIdle = true
        idleThresholdMinutes = Self.defaultIdleThresholdMinutes
        autoStopEnabled = false
        autoStopDelayMinutes = Self.defaultAutoStopDelayMinutes
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        userDefaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private func int(_ key: String, default defaultValue: Int) -> Int {
        guard let value = userDefaults.object(forKey: key) as? Int, value > 0 else {
            return defaultValue
        }
        return value
    }
}
