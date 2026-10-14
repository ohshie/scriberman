import AppKit
import SwiftUI

/// Owns the floating "Recording failed." panel.
///
/// Uses a panel rather than a user notification for the same reasons as
/// `IdleSessionPromptController` — notification banner-vs-alert style is a user preference the app
/// cannot force, so a banner could auto-dismiss to Notification Center unseen. That matters more
/// here than anywhere else in the app: the failure this reports is the user believing a meeting is
/// being recorded when nothing was captured.
@MainActor
final class RecordingStartFailureController {
    private var panel: NSPanel?

    func show(onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(
            rootView: RecordingStartFailureView(onOpen: onOpen, onDismiss: onDismiss)
        )
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 320, height: 110))
        position(panel)
        // orderFrontRegardless so the panel appears without activating Scriberman — the user may
        // be in a meeting window, and stealing focus mid-call is its own harm.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        FloatingPanel(size: NSSize(width: 320, height: 110))
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
