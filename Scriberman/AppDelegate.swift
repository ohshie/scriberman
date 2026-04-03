import AppKit
import OSLog
import SwiftData

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static let focusPendingSessionNotification = Notification.Name("Scriberman.FocusPendingSession")
    static let focusRecordingSessionNotification = Notification.Name("Scriberman.FocusRecordingSession")

    weak var appState: AppState?
    var modelContext: ModelContext?

    private weak var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let logger = Logger(subsystem: "Scriberman", category: "MenuBarFlow")

    func applicationDidBecomeActive(_ notification: Notification) {
        attachWindowDelegateIfNeeded()
        syncStatusItemVisibilityFromSettings()
        ensureMainWindowVisibleIfNeeded()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let appState else {
            return true
        }

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
            logger.info("windowShouldClose closeAction=ask -> showFirstTimeTrayAlert")
            showFirstTimeTrayAlert(window: sender)
            return false
        }
    }

    func hideToTray(window: NSWindow? = nil) {
        appState?.menuBarSettings.isInTrayMode = true
        ensureStatusItemVisible()
        let windowToHide = window ?? resolveMainWindow()
        windowToHide?.orderOut(nil)
        let changed = NSApp.setActivationPolicy(.accessory)
        logger.info(
            "hideToTray activationPolicyChanged=\(changed) currentPolicy=\(String(describing: NSApp.activationPolicy), privacy: .public)"
        )
    }

    func showMainWindow() {
        guard let window = resolveMainWindow() else {
            logger.info("showMainWindow no window resolved")
            return
        }

        let changed = NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        logger.info(
            "showMainWindow activationPolicyChanged=\(changed) currentPolicy=\(String(describing: NSApp.activationPolicy), privacy: .public)"
        )
        syncStatusItemVisibilityFromSettings()
        NotificationCenter.default.post(name: Self.focusPendingSessionNotification, object: nil)
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

    private func ensureMainWindowVisibleIfNeeded() {
        guard let appState else {
            return
        }

        guard appState.menuBarSettings.isInTrayMode == false else {
            return
        }

        guard let window = resolveMainWindow() else {
            return
        }

        if window.isVisible == false {
            showMainWindow()
        }
    }

    private func syncStatusItemVisibilityFromSettings() {
        guard let appState else {
            return
        }

        if appState.menuBarSettings.isInTrayMode {
            ensureStatusItemVisible()
        } else {
            removeStatusItem()
        }
    }

    private func ensureStatusItemVisible() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.isVisible = true
            statusItem = item
            logger.info("Created NSStatusItem fallback")
        }

        guard let statusItem else {
            return
        }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Scriberman")
            button.imagePosition = .imageOnly
            button.appearsDisabled = false
        }

        if statusItem.menu == nil {
            statusItem.menu = makeStatusMenu()
        } else if let menu = statusItem.menu {
            rebuildStatusMenu(menu)
        }
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }

        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        logger.info("Removed NSStatusItem")
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        rebuildStatusMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        guard let appState else {
            addOpenAndQuitItems(to: menu)
            return
        }

        switch appState.newSessionViewModel.state {
        case .idle:
            appState.audioDeviceService.refreshDevices()
            appState.appAudioService.refreshRunningApps()
            addIdleItems(to: menu)
        case let .recording(duration, _):
            addRecordingItems(to: menu, duration: duration)
        }
    }

    private func addIdleItems(to menu: NSMenu) {
        let startItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(startQuickRecordingFromStatusItem),
            keyEquivalent: ""
        )
        startItem.target = self
        menu.addItem(startItem)

        let recordWithItem = NSMenuItem(title: "Record with…", action: nil, keyEquivalent: "")
        recordWithItem.submenu = makeRecordWithSubmenu()
        menu.addItem(recordWithItem)

        menu.addItem(.separator())
        addOpenAndQuitItems(to: menu)
    }

    private func addRecordingItems(to menu: NSMenu, duration: TimeInterval) {
        let durationItem = NSMenuItem(title: "Recording: \(menuDuration(duration))", action: nil, keyEquivalent: "")
        durationItem.isEnabled = false
        menu.addItem(durationItem)

        let stopItem = NSMenuItem(
            title: "Stop Recording",
            action: #selector(stopRecordingFromStatusItem),
            keyEquivalent: ""
        )
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())
        addOpenAndQuitItems(to: menu)
    }

    private func addOpenAndQuitItems(to menu: NSMenu) {
        let openItem = NSMenuItem(
            title: "Open Scriberman",
            action: #selector(openScribermanFromStatusItem),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Scriberman",
            action: #selector(quitScribermanFromStatusItem),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func makeRecordWithSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let micHeader = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micHeader.isEnabled = false
        submenu.addItem(micHeader)

        if let appState {
            for device in appState.audioDeviceService.availableDevices {
                let item = NSMenuItem(
                    title: device.name,
                    action: #selector(selectMicrophoneFromStatusItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = device.uid
                item.state = appState.menuBarSettings.lastUsedMicUID == device.uid ? .on : .off
                submenu.addItem(item)
            }

            submenu.addItem(.separator())

            let appHeader = NSMenuItem(title: "App Audio", action: nil, keyEquivalent: "")
            appHeader.isEnabled = false
            submenu.addItem(appHeader)

            let noAppAudioItem = NSMenuItem(
                title: "No App Audio",
                action: #selector(selectNoAppAudioFromStatusItem),
                keyEquivalent: ""
            )
            noAppAudioItem.target = self
            noAppAudioItem.state = appState.menuBarSettings.lastUsedAppBundleID == nil ? .on : .off
            submenu.addItem(noAppAudioItem)

            for app in appState.appAudioService.runningApps {
                let item = NSMenuItem(
                    title: app.name,
                    action: #selector(selectAppAudioFromStatusItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = app.bundleID
                item.state = appState.menuBarSettings.lastUsedAppBundleID == app.bundleID ? .on : .off
                submenu.addItem(item)
            }
        }

        return submenu
    }

    private func startQuickRecording() {
        guard let appState, let modelContext else {
            logger.error("startQuickRecording missing appState or modelContext")
            return
        }

        appState.selectPendingSession()
        appState.requestPendingSessionFocusFromMenuBar()
        NotificationCenter.default.post(name: Self.focusPendingSessionNotification, object: nil)
        appState.appAudioService.refreshRunningApps()

        let selectedMic = appState.menuBarSettings.lastUsedMicUID
        let selectedApp = appState.appAudioService.runningApps.first {
            $0.bundleID == appState.menuBarSettings.lastUsedAppBundleID
        }
        let title = appState.pendingSession?.title ?? "Untitled Session"

        Task {
            await appState.newSessionViewModel.startRecording(
                title: title,
                micDeviceUID: selectedMic,
                app: selectedApp,
                context: modelContext
            )
        }
    }

    @objc
    private func startQuickRecordingFromStatusItem() {
        startQuickRecording()
    }

    @objc
    private func stopRecordingFromStatusItem() {
        guard let appState, let modelContext else {
            logger.error("stopRecordingFromStatusItem missing appState or modelContext")
            return
        }

        Task {
            if let session = await appState.newSessionViewModel.stopRecording(context: modelContext) {
                NotificationCenter.default.post(
                    name: Self.focusRecordingSessionNotification,
                    object: nil,
                    userInfo: ["sessionID": session.id]
                )
            }
        }
    }

    @objc
    private func selectMicrophoneFromStatusItem(_ sender: NSMenuItem) {
        guard let appState else {
            return
        }

        appState.menuBarSettings.lastUsedMicUID = sender.representedObject as? String
    }

    @objc
    private func selectNoAppAudioFromStatusItem() {
        guard let appState else {
            return
        }

        appState.menuBarSettings.lastUsedAppBundleID = nil
    }

    @objc
    private func selectAppAudioFromStatusItem(_ sender: NSMenuItem) {
        guard let appState else {
            return
        }

        appState.menuBarSettings.lastUsedAppBundleID = sender.representedObject as? String
    }

    private func menuDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    @objc
    private func openScribermanFromStatusItem() {
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
        }
    }

    @objc
    private func quitScribermanFromStatusItem() {
        NSApp.terminate(nil)
    }
}
