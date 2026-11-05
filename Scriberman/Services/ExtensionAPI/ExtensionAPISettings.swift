import Foundation
import Observation

/// Whether the local extension API listens, and on which port. Off until the user turns it on;
/// nothing has to be set up by hand.
///
/// Values are stored properties so `@Observable` publishes their changes (see
/// `IdlePromptPreferences`).
@MainActor
@Observable
final class ExtensionAPISettings {
    struct InvalidPort: Error, Equatable {
        let port: Int
    }

    private enum Key {
        static let isEnabled = "extensionAPI.isEnabled"
        static let port = "extensionAPI.port"
    }

    static let defaultPort = 47615
    static let validPorts = 1024...65535

    @ObservationIgnored private let userDefaults: UserDefaults

    var isEnabled: Bool {
        didSet { userDefaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    private(set) var port: Int

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isEnabled = userDefaults.bool(forKey: Key.isEnabled)
        let stored = userDefaults.object(forKey: Key.port) as? Int
        port = stored.flatMap { Self.validPorts.contains($0) ? $0 : nil } ?? Self.defaultPort
    }

    /// Changes the port, or throws and keeps the current one when `port` is outside 1024...65535.
    func setPort(_ port: Int) throws {
        guard Self.validPorts.contains(port) else {
            throw InvalidPort(port: port)
        }
        self.port = port
        userDefaults.set(port, forKey: Key.port)
    }
}
