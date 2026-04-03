import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var appState: AppState?

    private weak var mainWindow: NSWindow?

    func applicationDidBecomeActive(_ notification: Notification) {
        attachWindowDelegateIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let appState else {
            return true
        }

        if appState.requiredOnboardingStep != nil {
            NSApp.terminate(nil)
            return false
        }

        switch appState.menuBarSettings.closeAction {
        case .quit:
            return true
        case .tray:
            hideToTray(window: sender)
            return false
        case .ask:
            if appState.menuBarSettings.hasShownFirstTimeTrayAlert {
                hideToTray(window: sender)
            } else {
                showFirstTimeTrayAlert(window: sender)
            }
            return false
        }
    }

    func hideToTray(window: NSWindow? = nil) {
        appState?.menuBarSettings.isInTrayMode = true
        let windowToHide = window ?? resolveMainWindow()
        windowToHide?.orderOut(nil)
        _ = NSApp.setActivationPolicy(.accessory)
    }

    func showMainWindow() {
        guard let window = resolveMainWindow() else {
            return
        }

        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
            return
        }

        guard mainWindow !== window || window.delegate !== self else {
            return
        }

        window.delegate = self
        mainWindow = window
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
