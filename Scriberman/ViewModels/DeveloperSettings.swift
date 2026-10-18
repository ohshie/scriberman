import Foundation
import Observation

/// Persisted state behind the hidden Dev Features tab in Settings: whether the tab is unlocked,
/// and the feature flag values it edits.
///
/// Flag values live under the flags' own keys in the same store `AudioSyncConfig` reads, so a
/// toggle here is what the next recording snapshots, and a `defaults write` override shows here.
/// A value is stored only while it differs from the flag's default; setting a flag back to its
/// default removes the key, so a later release that changes the default applies.
@MainActor
@Observable
final class DeveloperSettings {
    private enum Key {
        static let isUnlocked = "developerSettings.isUnlocked"
        static let betaBuildsEnabled = "developerSettings.betaBuildsEnabled"
    }

    /// Clicks on the version label in Settings that unlock the tab.
    static let unlockClickCount = 7

    @ObservationIgnored private let store: UserDefaults
    let flagDefinitions: AudioSyncConfig.FlagDefinitions

    /// Held in memory only; never persisted.
    @ObservationIgnored private var versionClickCount = 0

    private(set) var isUnlocked: Bool {
        didSet { store.set(isUnlocked, forKey: Key.isUnlocked) }
    }

    /// Whether update checks offer beta releases. `UpdateService` reads it at launch and applies
    /// changes to the updater.
    private(set) var betaBuildsEnabled: Bool {
        didSet { store.set(betaBuildsEnabled, forKey: Key.betaBuildsEnabled) }
    }

    /// Stored rather than read through to `store` on each access, because `@Observable` tracks
    /// stored properties only.
    private var flagValues: [String: Bool]

    var flags: [AudioSyncConfig.Flag] { flagDefinitions.all }

    init(store: UserDefaults = .standard, flagDefinitions: AudioSyncConfig.FlagDefinitions = .shipped) {
        self.store = store
        self.flagDefinitions = flagDefinitions
        isUnlocked = store.bool(forKey: Key.isUnlocked)
        betaBuildsEnabled = store.bool(forKey: Key.betaBuildsEnabled)
        flagValues = Dictionary(uniqueKeysWithValues: flagDefinitions.all.map {
            ($0.key, store.object(forKey: $0.key) as? Bool ?? $0.defaultValue)
        })
    }

    func registerVersionClick() {
        guard !isUnlocked else { return }
        versionClickCount += 1
        if versionClickCount >= Self.unlockClickCount {
            versionClickCount = 0
            isUnlocked = true
        }
    }

    func settingsDidClose() {
        versionClickCount = 0
    }

    /// Removes the tab. Flag values and the beta builds opt-in are left as they are.
    func hide() {
        versionClickCount = 0
        isUnlocked = false
    }

    func setBetaBuilds(_ enabled: Bool) {
        betaBuildsEnabled = enabled
    }

    func isOn(_ flag: AudioSyncConfig.Flag) -> Bool {
        flagValues[flag.key] ?? flag.defaultValue
    }

    func set(_ flag: AudioSyncConfig.Flag, isOn: Bool) {
        flagValues[flag.key] = isOn
        if isOn == flag.defaultValue {
            store.removeObject(forKey: flag.key)
        } else {
            store.set(isOn, forKey: flag.key)
        }
    }
}
