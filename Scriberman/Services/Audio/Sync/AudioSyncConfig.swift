import Foundation

/// Feature flags for the synchronized-capture work. Kept behind a flag so the new
/// timestamp-anchored timeline path can run alongside the legacy constant-offset
/// mixdown and be A/B compared before becoming the default (see the
/// `synchronized-audio-capture` change).
enum AudioSyncConfig {
    private static let timelineMixdownKey = "AudioSync.timelineMixdownEnabled"

    /// When true, mixdown places samples on the shared presentation-time timeline
    /// (`SynchronizedAudioTimeline`, gap/outage silence-fill) instead of the single constant
    /// start-offset. **Default ON** (unset ⇒ true); the legacy offset path remains only as a
    /// graceful fallback when timing sidecars are missing/inconsistent. Force off with
    /// `defaults write <bundle> AudioSync.timelineMixdownEnabled -bool NO`.
    static var isTimelineMixdownEnabled: Bool {
        get { UserDefaults.standard.object(forKey: timelineMixdownKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: timelineMixdownKey) }
    }

    private static let unifiedCaptureKey = "AudioSync.unifiedCaptureEnabled"

    /// Phase 2: when true, mic + app are captured from one ScreenCaptureKit stream
    /// (macOS 15+ `captureMicrophone`) for a shared clock, instead of AVAudioEngine mic +
    /// a separate SCStream. Applies to mic+app recordings; the AVAudioEngine path remains as a
    /// fallback when unified capture cannot start. **Default ON** (unset ⇒ true). Force off with
    /// `defaults write <bundle> AudioSync.unifiedCaptureEnabled -bool NO`.
    static var isUnifiedCaptureEnabled: Bool {
        get { UserDefaults.standard.object(forKey: unifiedCaptureKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: unifiedCaptureKey) }
    }

    private static let captureHealthRecoveryKey = "AudioSync.captureHealthRecoveryEnabled"

    /// When true, a recording whose capture dies mid-session is restarted in place and, if that
    /// does not help within the budget, stopped and reported. When false, capture health is still
    /// evaluated and logged but nothing acts on it — behaviour is exactly as before.
    ///
    /// **Default ON** (unset ⇒ true), after validation on real hardware with a forced mid-session
    /// stream kill. It shipped default-off first because two prior audio-sync changes passed their
    /// tests and regressed on real hardware, and this one touches the timeline. Force off with
    /// `defaults write <bundle> AudioSync.captureHealthRecoveryEnabled -bool NO`, which returns
    /// capture health to evaluating and logging without acting.
    static var isCaptureHealthRecoveryEnabled: Bool {
        get { UserDefaults.standard.object(forKey: captureHealthRecoveryKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: captureHealthRecoveryKey) }
    }
}
