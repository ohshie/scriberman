import Foundation
import Observation

/// Persisted configuration for the idle session prompt.
///
/// Values are stored properties (not computed accessors over `UserDefaults`) because the
/// `@Observable` macro only tracks stored properties — computed ones publish no change, so
/// bound controls would write their value but never re-render.
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

    @ObservationIgnored private let userDefaults: UserDefaults

    var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    var watchAppAudio: Bool {
        didSet { userDefaults.set(watchAppAudio, forKey: Key.watchAppAudio) }
    }

    var watchMicAudio: Bool {
        didSet { userDefaults.set(watchMicAudio, forKey: Key.watchMicAudio) }
    }

    var watchUserInput: Bool {
        didSet { userDefaults.set(watchUserInput, forKey: Key.watchUserInput) }
    }

    var requiresAllSourcesIdle: Bool {
        didSet { userDefaults.set(requiresAllSourcesIdle, forKey: Key.requiresAllSourcesIdle) }
    }

    /// Backing store for the clamped minute values. Clamping happens in the facade's setter
    /// below rather than in a `didSet`: under `@Observable` a property is no longer a plain
    /// stored property, so assigning to it inside its own `didSet` re-enters the synthesized
    /// setter and recurses until the stack overflows.
    private var storedIdleThresholdMinutes: Int

    var idleThresholdMinutes: Int {
        get { storedIdleThresholdMinutes }
        set {
            storedIdleThresholdMinutes = max(1, newValue)
            userDefaults.set(storedIdleThresholdMinutes, forKey: Key.idleThresholdMinutes)
        }
    }

    var autoStopEnabled: Bool {
        didSet { userDefaults.set(autoStopEnabled, forKey: Key.autoStopEnabled) }
    }

    private var storedAutoStopDelayMinutes: Int

    var autoStopDelayMinutes: Int {
        get { storedAutoStopDelayMinutes }
        set {
            storedAutoStopDelayMinutes = max(1, newValue)
            userDefaults.set(storedAutoStopDelayMinutes, forKey: Key.autoStopDelayMinutes)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        // Unset keys fall back to the shipped defaults; an explicit `false` is preserved.
        isEnabled = userDefaults.object(forKey: Key.isEnabled) as? Bool ?? true
        watchAppAudio = userDefaults.object(forKey: Key.watchAppAudio) as? Bool ?? true
        watchMicAudio = userDefaults.object(forKey: Key.watchMicAudio) as? Bool ?? false
        watchUserInput = userDefaults.object(forKey: Key.watchUserInput) as? Bool ?? false
        requiresAllSourcesIdle = userDefaults.object(forKey: Key.requiresAllSourcesIdle) as? Bool ?? true
        let threshold = userDefaults.object(forKey: Key.idleThresholdMinutes) as? Int
        storedIdleThresholdMinutes = (threshold.map { max(1, $0) }) ?? Self.defaultIdleThresholdMinutes
        autoStopEnabled = userDefaults.object(forKey: Key.autoStopEnabled) as? Bool ?? false
        let delay = userDefaults.object(forKey: Key.autoStopDelayMinutes) as? Int
        storedAutoStopDelayMinutes = (delay.map { max(1, $0) }) ?? Self.defaultAutoStopDelayMinutes
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
}
