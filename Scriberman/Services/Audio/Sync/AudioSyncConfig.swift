import Foundation

/// Feature flags for the synchronized-capture work. Kept behind a flag so the new
/// timestamp-anchored timeline path can run alongside the legacy constant-offset
/// mixdown and be A/B compared before becoming the default (see the
/// `synchronized-audio-capture` change).
///
/// Each flag is read from `store` on every access; a key with no stored value reads as its
/// definition's default. Production uses `UserDefaults.standard` and `FlagDefinitions.shipped`,
/// so `defaults write` overrides apply. Tests pass their own store and definitions.
///
/// `@unchecked` because `UserDefaults` is not marked `Sendable`; Apple documents it as thread-safe.
struct AudioSyncConfig: @unchecked Sendable {
    /// A flag's backing key and the value it reads as when the key is unset.
    struct Flag: Sendable, Equatable {
        let key: String
        let defaultValue: Bool
    }

    struct FlagDefinitions: Sendable, Equatable {
        var timelineMixdown: Flag
        var unifiedCapture: Flag
        var captureHealthRecovery: Flag

        static let shipped = FlagDefinitions(
            timelineMixdown: Flag(key: "AudioSync.timelineMixdownEnabled", defaultValue: true),
            unifiedCapture: Flag(key: "AudioSync.unifiedCaptureEnabled", defaultValue: true),
            captureHealthRecovery: Flag(key: "AudioSync.captureHealthRecoveryEnabled", defaultValue: true)
        )

        /// Every flag, in the order the Dev Features tab lists them.
        var all: [Flag] { [timelineMixdown, unifiedCapture, captureHealthRecovery] }
    }

    private let store: UserDefaults
    let definitions: FlagDefinitions

    init(store: UserDefaults = .standard, definitions: FlagDefinitions = .shipped) {
        self.store = store
        self.definitions = definitions
    }

    /// When true, mixdown places samples on the shared presentation-time timeline
    /// (`SynchronizedAudioTimeline`, gap/outage silence-fill) instead of the single constant
    /// start-offset. **Default ON** (unset ⇒ true); the legacy offset path remains only as a
    /// graceful fallback when timing sidecars are missing/inconsistent. Force off with
    /// `defaults write <bundle> AudioSync.timelineMixdownEnabled -bool NO`.
    var isTimelineMixdownEnabled: Bool { value(of: definitions.timelineMixdown) }

    /// Phase 2: when true, mic + app are captured from one ScreenCaptureKit stream
    /// (macOS 15+ `captureMicrophone`) for a shared clock, instead of AVAudioEngine mic +
    /// a separate SCStream. Applies to mic+app recordings; the AVAudioEngine path remains as a
    /// fallback when unified capture cannot start. **Default ON** (unset ⇒ true). Force off with
    /// `defaults write <bundle> AudioSync.unifiedCaptureEnabled -bool NO`.
    var isUnifiedCaptureEnabled: Bool { value(of: definitions.unifiedCapture) }

    /// When true, a recording whose capture dies mid-session is restarted in place and, if that
    /// does not help within the budget, stopped and reported. When false, capture health is still
    /// evaluated and logged but nothing acts on it — behaviour is exactly as before.
    ///
    /// **Default ON** (unset ⇒ true), after validation on real hardware with a forced mid-session
    /// stream kill. It shipped default-off first because two prior audio-sync changes passed their
    /// tests and regressed on real hardware, and this one touches the timeline. Force off with
    /// `defaults write <bundle> AudioSync.captureHealthRecoveryEnabled -bool NO`, which returns
    /// capture health to evaluating and logging without acting.
    var isCaptureHealthRecoveryEnabled: Bool { value(of: definitions.captureHealthRecovery) }

    /// All three flags read now, for one recording to use from start to finalization.
    func snapshot() -> AudioSyncFlags {
        AudioSyncFlags(
            isTimelineMixdownEnabled: isTimelineMixdownEnabled,
            isUnifiedCaptureEnabled: isUnifiedCaptureEnabled,
            isCaptureHealthRecoveryEnabled: isCaptureHealthRecoveryEnabled
        )
    }

    private func value(of flag: Flag) -> Bool {
        store.object(forKey: flag.key) as? Bool ?? flag.defaultValue
    }
}

/// The audio-sync flag values one recording was started with. Read once at start, then passed to
/// capture, capture health, finalization, and recovery, so a flag change applies from the next
/// recording and never to one in progress.
struct AudioSyncFlags: Sendable, Equatable {
    let isTimelineMixdownEnabled: Bool
    let isUnifiedCaptureEnabled: Bool
    let isCaptureHealthRecoveryEnabled: Bool

    /// The values of `FlagDefinitions.shipped` with nothing stored.
    static let shippedDefaults = AudioSyncFlags(
        isTimelineMixdownEnabled: AudioSyncConfig.FlagDefinitions.shipped.timelineMixdown.defaultValue,
        isUnifiedCaptureEnabled: AudioSyncConfig.FlagDefinitions.shipped.unifiedCapture.defaultValue,
        isCaptureHealthRecoveryEnabled: AudioSyncConfig.FlagDefinitions.shipped.captureHealthRecovery.defaultValue
    )
}
