import Foundation
import Observation

@Observable
@MainActor
final class DictationHotkeySettings {
    private let defaults: UserDefaults
    private let hotkeyKey = "dictationHotkeyCombo"

    private(set) var combo: HotkeyCombo

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.combo = Self.loadCombo(from: defaults)
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

    private static func loadCombo(from defaults: UserDefaults) -> HotkeyCombo {
        guard let data = defaults.data(forKey: "dictationHotkeyCombo"),
              let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data)
        else {
            return .defaultDictation
        }
        return combo
    }
}
