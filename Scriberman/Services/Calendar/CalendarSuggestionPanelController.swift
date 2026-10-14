import AppKit
import SwiftUI

/// Owns the floating meeting-suggestion panel. Same placement and behavior as the idle session
/// prompt: top-right, across Spaces, and shown without activating Scriberman.
@MainActor
final class CalendarSuggestionPanelController {
    private var panel: NSPanel?

    func show(
        _ suggestions: [CalendarMeetingSuggestion],
        onPrepare: @escaping (CalendarOccurrenceID) -> Void,
        onDismiss: @escaping (CalendarOccurrenceID) -> Void
    ) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(
            rootView: CalendarSuggestionPanelView(
                suggestions: suggestions,
                onPrepare: onPrepare,
                onDismiss: onDismiss
            )
        )
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 320, height: 120))
        position(panel)
        // orderFrontRegardless so the panel appears without activating Scriberman.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        FloatingPanel(size: NSSize(width: 320, height: 120))
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
