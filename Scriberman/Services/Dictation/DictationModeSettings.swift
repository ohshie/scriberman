import Foundation
import Observation

/// When dictated text reaches the focused app.
enum DictationMode: String, CaseIterable, Sendable {
    /// The whole hold is transcribed once, after the hotkey is released.
    case releaseTime
    /// Words are typed during the hold once consecutive passes agree on them.
    case progressive
}

@Observable
@MainActor
final class DictationModeSettings {
    static let modeKey = "dictationMode"

    private let defaults: UserDefaults

    private(set) var mode: DictationMode

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Absent or unknown values (older builds, rolled-back modes) mean release-time.
        self.mode = defaults.string(forKey: Self.modeKey).flatMap(DictationMode.init(rawValue:)) ?? .releaseTime
    }

    func setMode(_ newMode: DictationMode) {
        mode = newMode
        defaults.set(newMode.rawValue, forKey: Self.modeKey)
    }
}
