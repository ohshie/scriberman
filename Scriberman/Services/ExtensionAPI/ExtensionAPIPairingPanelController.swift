import AppKit
import SwiftUI

/// Owns the floating pairing prompt. Same placement and behavior as the idle session prompt:
/// top-right, across Spaces, and shown without activating Scriberman.
@MainActor
final class ExtensionAPIPairingPanelController {
    private var panel: NSPanel?

    func show(
        _ request: ExtensionAPIPairingRequest,
        onApprove: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        let panel = self.panel ?? FloatingPanel(size: NSSize(width: 320, height: 160))
        self.panel = panel

        panel.contentView = NSHostingView(
            rootView: ExtensionAPIPairingPanelView(
                content: ExtensionAPIPairingPromptContent(request),
                onApprove: onApprove,
                onDeny: onDeny
            )
        )
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 320, height: 160))
        position(panel)
        // orderFrontRegardless so the panel appears without activating Scriberman.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
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
