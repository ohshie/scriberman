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
        didSet { userDefaults.set(isInTrayMode, forKey: Key.isInTrayMode) }
    }

    var closeAction: CloseAction {
        didSet { userDefaults.set(closeAction.rawValue, forKey: Key.closeAction) }
    }

    var hasShownFirstTimeTrayAlert: Bool {
        didSet { userDefaults.set(hasShownFirstTimeTrayAlert, forKey: Key.hasShownFirstTimeTrayAlert) }
    }

    var lastUsedMicUID: String? {
        didSet { userDefaults.set(lastUsedMicUID, forKey: Key.lastUsedMicUID) }
    }

    var lastUsedAppBundleID: String? {
        didSet { userDefaults.set(lastUsedAppBundleID, forKey: Key.lastUsedAppBundleID) }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        isInTrayMode = userDefaults.bool(forKey: Key.isInTrayMode)
        closeAction = userDefaults.string(forKey: Key.closeAction).flatMap(CloseAction.init(rawValue:)) ?? .ask
        hasShownFirstTimeTrayAlert = userDefaults.bool(forKey: Key.hasShownFirstTimeTrayAlert)
        lastUsedMicUID = userDefaults.string(forKey: Key.lastUsedMicUID)
        lastUsedAppBundleID = userDefaults.string(forKey: Key.lastUsedAppBundleID)
    }
}
