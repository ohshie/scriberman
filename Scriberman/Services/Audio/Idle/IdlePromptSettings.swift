import Foundation

/// User configuration for the idle session prompt. Pure value type; persistence lives in
/// `AppAudioSettings`-style storage.
struct IdlePromptSettings: Equatable, Sendable {
    /// Master switch for the feature.
    var isEnabled: Bool
    /// Watch app audio for activity (on by default — the primary signal).
    var watchAppAudio: Bool
    /// Watch the microphone for activity.
    var watchMicAudio: Bool
    /// Watch mouse/keyboard input for activity.
    var watchUserInput: Bool
    /// When several sources are watched: true = every watched source must be idle before
    /// prompting (default, conservative); false = any single idle source is enough.
    var requiresAllSourcesIdle: Bool
    /// How long the session must be idle before the prompt appears.
    var idleThreshold: TimeInterval
    /// Stop the recording automatically when the prompt is ignored.
    var autoStopEnabled: Bool
    /// How long an ignored prompt waits before automatic stop.
    var autoStopDelay: TimeInterval

    static let defaultIdleThreshold: TimeInterval = 5 * 60
    static let defaultAutoStopDelay: TimeInterval = 5 * 60

    static let `default` = IdlePromptSettings(
        isEnabled: true,
        watchAppAudio: true,
        watchMicAudio: false,
        watchUserInput: false,
        requiresAllSourcesIdle: true,
        idleThreshold: defaultIdleThreshold,
        autoStopEnabled: false,
        autoStopDelay: defaultAutoStopDelay
    )

    /// Number of sources currently watched. The all/any rule is meaningless below two.
    var watchedSourceCount: Int {
        [watchAppAudio, watchMicAudio, watchUserInput].filter { $0 }.count
    }
}

/// Last-activity timestamps for everything the prompt can watch. `nil` means the source
/// produced no activity yet (or, for the microphone under the AVAudioRecorder fallback,
/// that no data is available).
struct IdleActivitySnapshot: Equatable, Sendable {
    var appAudio: Date?
    var micAudio: Date?
    var userInput: Date?

    init(appAudio: Date? = nil, micAudio: Date? = nil, userInput: Date? = nil) {
        self.appAudio = appAudio
        self.micAudio = micAudio
        self.userInput = userInput
    }
}
