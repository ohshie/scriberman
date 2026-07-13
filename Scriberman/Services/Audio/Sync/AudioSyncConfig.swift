import Foundation

/// Feature flags for the synchronized-capture work. Kept behind a flag so the new
/// timestamp-anchored timeline path can run alongside the legacy constant-offset
/// mixdown and be A/B compared before becoming the default (see the
/// `synchronized-audio-capture` change).
enum AudioSyncConfig {
    private static let timelineMixdownKey = "AudioSync.timelineMixdownEnabled"

    /// When true, mixdown/capture should place samples on the shared presentation-time
    /// timeline (`SynchronizedAudioTimeline`) instead of the single constant start-offset.
    /// Defaults to false until Phase 1 passes its drift-acceptance measurement.
    static var isTimelineMixdownEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: timelineMixdownKey) }
        set { UserDefaults.standard.set(newValue, forKey: timelineMixdownKey) }
    }
}
