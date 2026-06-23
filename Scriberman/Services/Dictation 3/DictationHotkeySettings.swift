import Foundation
import Observation

@Observable
@MainActor
final class DictationHotkeySettings {
    enum DevicePreference: String, Codable {
        case recordingDevice
        case systemDefault
    }

    private let defaults: UserDefaults
    private let hotkeyKey = "dictationHotkeyCombo"
    private let devicePreferenceKey = "dictationDevicePreference"

    private(set) var combo: HotkeyCombo
    var devicePreference: DevicePreference {
        didSet { persistDevicePreference() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.combo = Self.loadCombo(from: defaults)
        self.devicePreference = Self.loadDevicePreference(from: defaults)
    }

    func setCombo(_ newCombo: HotkeyCombo) -> Bool {
        guard newCombo.isValid else { return false }
        combo = newCombo
        persistCombo()
        return true
    }

    private func persistCombo() {
        if let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: hotkeyKey)
        }
    }

    private func persistDevicePreference() {
        defaults.set(devicePreference.rawValue, forKey: devicePreferenceKey)
    }

    private static func loadCombo(from defaults: UserDefaults) -> HotkeyCombo {
        guard let data = defaults.data(forKey: "dictationHotkeyCombo"),
              let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data)
        else {
            return .defaultDictation
        }
        return combo
    }

    private static func loadDevicePreference(from defaults: UserDefaults) -> DevicePreference {
        guard let raw = defaults.string(forKey: "dictationDevicePreference"),
              let pref = DevicePreference(rawValue: raw)
        else {
            return .recordingDevice
        }
        return pref
    }
}
