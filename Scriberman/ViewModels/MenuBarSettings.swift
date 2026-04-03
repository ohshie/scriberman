import Foundation
import Observation

@MainActor
@Observable
final class MenuBarSettings {
    enum CloseAction: String, CaseIterable {
        case ask
        case tray
        case quit
    }

    private enum Key {
        static let isInTrayMode = "menuBar.isInTrayMode"
        static let closeAction = "menuBar.closeAction"
        static let hasShownFirstTimeTrayAlert = "menuBar.hasShownFirstTimeTrayAlert"
        static let lastUsedMicUID = "menuBar.lastUsedMicUID"
        static let lastUsedAppBundleID = "menuBar.lastUsedAppBundleID"
    }

    private let userDefaults: UserDefaults
    var isInTrayMode: Bool {
        get { userDefaults.bool(forKey: Key.isInTrayMode) }
        set {
            userDefaults.set(newValue, forKey: Key.isInTrayMode)
        }
    }

    var closeAction: CloseAction {
        get {
            guard
                let rawValue = userDefaults.string(forKey: Key.closeAction),
                let action = CloseAction(rawValue: rawValue)
            else {
                return .ask
            }

            return action
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Key.closeAction)
        }
    }

    var hasShownFirstTimeTrayAlert: Bool {
        get { userDefaults.bool(forKey: Key.hasShownFirstTimeTrayAlert) }
        set {
            userDefaults.set(newValue, forKey: Key.hasShownFirstTimeTrayAlert)
        }
    }

    var lastUsedMicUID: String? {
        get { userDefaults.string(forKey: Key.lastUsedMicUID) }
        set {
            userDefaults.set(newValue, forKey: Key.lastUsedMicUID)
        }
    }

    var lastUsedAppBundleID: String? {
        get { userDefaults.string(forKey: Key.lastUsedAppBundleID) }
        set {
            userDefaults.set(newValue, forKey: Key.lastUsedAppBundleID)
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
}
