import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var appState: AppState?

    private weak var mainWindow: NSWindow?
    private let logger = Logger(subsystem: "Scriberman", category: "MenuBarFlow")

    func applicationDidBecomeActive(_ notification: Notification) {
        logger.info("applicationDidBecomeActive")
        attachWindowDelegateIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let appState else {
            logger.info("windowShouldClose without appState; allowing close")
            return true
        }

        logger.info(
            "windowShouldClose step=\(String(describing: appState.requiredOnboardingStep), privacy: .public) closeAction=\(appState.menuBarSettings.closeAction.rawValue, privacy: .public) shownAlert=\(appState.menuBarSettings.hasShownFirstTimeTrayAlert) inTrayMode=\(appState.menuBarSettings.isInTrayMode)"
        )

        if appState.requiredOnboardingStep != nil {
            logger.info("windowShouldClose onboarding incomplete -> terminate")
            NSApp.terminate(nil)
            return false
        }

        switch appState.menuBarSettings.closeAction {
        case .quit:
            logger.info("windowShouldClose closeAction=quit -> allow close")
            return true
        case .tray:
            logger.info("windowShouldClose closeAction=tray -> hideToTray")
            hideToTray(window: sender)
            return false
        case .ask:
            if appState.menuBarSettings.hasShownFirstTimeTrayAlert {
                logger.info("windowShouldClose closeAction=ask shownAlert=true -> hideToTray")
                hideToTray(window: sender)
            } else {
                logger.info("windowShouldClose closeAction=ask shownAlert=false -> showFirstTimeTrayAlert")
                showFirstTimeTrayAlert(window: sender)
            }
            return false
        }
    }

    func hideToTray(window: NSWindow? = nil) {
        logger.info("hideToTray begin")
        appState?.menuBarSettings.isInTrayMode = true
        let windowToHide = window ?? resolveMainWindow()
        windowToHide?.orderOut(nil)
        let changed = NSApp.setActivationPolicy(.accessory)
        logger.info(
            "hideToTray activationPolicyChanged=\(changed) currentPolicy=\(String(describing: NSApp.activationPolicy), privacy: .public)"
        )

        // If the system/user customization immediately rejects insertion, recover
        // by restoring the main window so the app never becomes inaccessible.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, let appState else {
                return
            }

            if appState.menuBarSettings.isInTrayMode {
                self.logger.info("hideToTray verification succeeded: menu bar item remains inserted")
                return
            }

            self.logger.error(
                "hideToTray verification failed: menu bar extra rejected; restoring regular activation and main window"
            )
            self.showMainWindow()
        }
    }

    func showMainWindow() {
        guard let window = resolveMainWindow() else {
            logger.info("showMainWindow no window resolved")
            return
        }

        let changed = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        logger.info(
            "showMainWindow activationPolicyChanged=\(changed) currentPolicy=\(String(describing: NSApp.activationPolicy), privacy: .public)"
        )
    }

    private func showFirstTimeTrayAlert(window: NSWindow) {
        guard let appState else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Keep Scriberman in Menu Bar?"
        alert.informativeText = "Closing Scriberman can keep it running in the menu bar, or you can quit the app."
        alert.addButton(withTitle: "Keep in Menu Bar")
        alert.addButton(withTitle: "Quit Scriberman")

        let rememberCheckbox = NSButton(checkboxWithTitle: "Remember my choice", target: nil, action: nil)
        rememberCheckbox.state = .off
        alert.accessoryView = rememberCheckbox

        let response = alert.runModal()
        let keepInMenuBar = response == .alertFirstButtonReturn
        let shouldRemember = rememberCheckbox.state == .on
        logger.info(
            "showFirstTimeTrayAlert response keepInMenuBar=\(keepInMenuBar) shouldRemember=\(shouldRemember)"
        )

        appState.menuBarSettings.hasShownFirstTimeTrayAlert = true

        if shouldRemember {
            appState.menuBarSettings.closeAction = keepInMenuBar ? .tray : .quit
        }

        if keepInMenuBar {
            appState.menuBarSettings.isInTrayMode = true
            hideToTray(window: window)
        } else {
            NSApp.terminate(nil)
        }
    }

    private func attachWindowDelegateIfNeeded() {
        guard let window = resolveMainWindow() else {
            logger.info("attachWindowDelegateIfNeeded no window resolved")
            return
        }

        guard mainWindow !== window || window.delegate !== self else {
            return
        }

        window.delegate = self
        mainWindow = window
        logger.info("attachWindowDelegateIfNeeded assigned delegate")
    }

    private func resolveMainWindow() -> NSWindow? {
        if let mainWindow {
            return mainWindow
        }

        if let candidate = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first {
            mainWindow = candidate
            return candidate
        }

        return nil
    }
}
