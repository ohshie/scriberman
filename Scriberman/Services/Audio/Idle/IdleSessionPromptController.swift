import AppKit
import SwiftUI

/// Owns the floating "Still in progress. Stop?" panel.
///
/// The panel deliberately replaces a user notification: notification banner-vs-alert style
/// is a user preference the app cannot force, so a banner could silently auto-dismiss to
/// Notification Center. A panel persists until acted on, needs no authorization prompt, and
/// still reaches the user across Spaces and over fullscreen apps.
///
/// It is placed in the top-right corner rather than centred so it is less likely to sit over
/// content the user is screen-sharing.
@MainActor
final class IdleSessionPromptController {
    private var panel: NSPanel?

    /// Shows the prompt, or updates the handlers of an already-visible one.
    func show(
        onStop: @escaping () -> Void,
        onSnooze: @escaping (TimeInterval) -> Void
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(
            rootView: IdleSessionPromptView(onStop: onStop, onSnooze: onSnooze)
        )
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 320, height: 120))
        position(panel)
        // orderFrontRegardless so the prompt appears without activating Scriberman.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = IdlePromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Follow the user across Spaces and over fullscreen apps — the reach that a
        // notification would otherwise have provided.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        ))
    }
}

/// Borderless panels refuse key status by default, which would make the buttons unclickable.
/// Accepting key status combined with `.nonactivatingPanel` lets the buttons work without
/// activating Scriberman or taking focus from the meeting app.
private final class IdlePromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
