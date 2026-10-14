import AppKit
import ApplicationServices
import SwiftUI

/// Owns the floating dictation feedback panel (design D5). The panel is
/// non-activating so the app that owns the insertion target keeps focus for
/// the entire dictation session.
@MainActor
final class DictationHUDController {
    private var panel: NSPanel?

    func show(for dictation: DictationService) {
        if panel == nil {
            panel = makePanel(for: dictation)
        }
        guard let panel else { return }
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(for dictation: DictationService) -> NSPanel {
        let view = DictationHUDView(
            dictation: dictation,
            onEnableAccessibility: { Self.promptForAccessibility() },
            onOpenSettings: { Self.openSettingsWindow() },
            onDismiss: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: view)

        let panel = FloatingPanel(size: NSSize(width: 420, height: 72), hasShadow: false)
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + 80
        ))
    }

    private static func promptForAccessibility() {
        // Literal key: the kAXTrustedCheckOptionPrompt global is not
        // concurrency-safe to reference under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private static func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
