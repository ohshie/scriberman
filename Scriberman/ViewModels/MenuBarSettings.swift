import Foundation
import Observation
import OSLog

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
    private let logger = Logger(subsystem: "Scriberman", category: "MenuBarSettings")

    var isInTrayMode: Bool {
        get { userDefaults.bool(forKey: Key.isInTrayMode) }
        set {
            userDefaults.set(newValue, forKey: Key.isInTrayMode)
            logger.info("set isInTrayMode=\(newValue)")
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
            logger.info("set closeAction=\(newValue.rawValue, privacy: .public)")
        }
    }

    var hasShownFirstTimeTrayAlert: Bool {
        get { userDefaults.bool(forKey: Key.hasShownFirstTimeTrayAlert) }
        set {
            userDefaults.set(newValue, forKey: Key.hasShownFirstTimeTrayAlert)
            logger.info("set hasShownFirstTimeTrayAlert=\(newValue)")
        }
    }

    var lastUsedMicUID: String? {
        get { userDefaults.string(forKey: Key.lastUsedMicUID) }
        set {
            userDefaults.set(newValue, forKey: Key.lastUsedMicUID)
            logger.info("set lastUsedMicUID=\(newValue ?? "nil", privacy: .public)")
        }
    }

    var lastUsedAppBundleID: String? {
        get { userDefaults.string(forKey: Key.lastUsedAppBundleID) }
        set {
            userDefaults.set(newValue, forKey: Key.lastUsedAppBundleID)
            logger.info("set lastUsedAppBundleID=\(newValue ?? "nil", privacy: .public)")
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
}
