import Foundation

struct AIProviderStore {
    private enum Keys {
        static let isEnabled = "aiProvider.isEnabled"
        static let selectedProvider = "aiProvider.selectedProvider"
        static let selectedModelID = "aiProvider.selectedModelID"
    }

    private let defaults: UserDefaults
    private(set) var isEnabled: Bool
    private(set) var selectedProvider: AIProvider
    private(set) var selectedModelID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.object(forKey: Keys.isEnabled) as? Bool ?? false
        self.selectedProvider = AIProvider(rawValue: defaults.string(forKey: Keys.selectedProvider) ?? "") ?? .openAI
        self.selectedModelID = defaults.string(forKey: Keys.selectedModelID)
    }

    mutating func setIsEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: Keys.isEnabled)
    }

    mutating func setSelectedProvider(_ value: AIProvider) {
        selectedProvider = value
        defaults.set(value.rawValue, forKey: Keys.selectedProvider)
    }

    mutating func setSelectedModelID(_ value: String?) {
        selectedModelID = value
        defaults.set(value, forKey: Keys.selectedModelID)
    }
}
