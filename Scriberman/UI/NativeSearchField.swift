import AppKit
import SwiftUI

/// `NSSearchField`, in SwiftUI.
///
/// The session list's field was a `TextField(.plain)` inside a hand-drawn capsule, which meant
/// maintaining by hand what the system already maintains: the metrics — it laid the glyph and the
/// placeholder onto separate lines until a height was pinned — the placeholder, the clear button,
/// the focus ring, and the appearance under whatever the current material is.
///
/// `.searchable(placement: .sidebar)` would give all of that in one line, and owns the entire row it
/// occupies: there is no supported way to seat the tag filter beside the field. The filter narrows
/// the same set the query searches, so it stays where it is and the field is wrapped instead.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    /// Changes when something asks for focus. The value itself means nothing; that it changed is
    /// the request.
    var focusRequest: Int
    /// Called when Escape is pressed on an already empty field, so the window can put focus back
    /// where it came from.
    var onEscapeWhileEmpty: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .default
        field.controlSize = .regular
        // The field shares its row with the filter control, so it takes what is left rather than
        // insisting on its ideal width.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self

        // Only when it actually differs: assigning during editing moves the insertion point.
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = prompt

        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.stopWatchingForEscape()
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var lastFocusRequest: Int
        /// Watches for Escape while this field is being edited.
        ///
        /// The delegate's `doCommandBy` is not enough on its own: SwiftUI shortcuts are handled at
        /// the window level, so a view elsewhere binding Escape — the transcript find bar does —
        /// takes the key before the field's own editor ever sees it. A local monitor runs first and
        /// consumes it, but only while the field is actually being edited.
        private var escapeMonitor: Any?

        init(parent: NativeSearchField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }

        deinit {
            if let escapeMonitor {
                NSEvent.removeMonitor(escapeMonitor)
            }
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            startWatchingForEscape(in: notification.object as? NSSearchField)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            stopWatchingForEscape()
        }

        func stopWatchingForEscape() {
            guard let escapeMonitor else { return }
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        private func startWatchingForEscape(in field: NSSearchField?) {
            stopWatchingForEscape()
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak field] event in
                guard let self, event.keyCode == 53 else { return event }
                // Only ours to handle while this field holds the keyboard.
                guard let field, field.currentEditor() != nil else { return event }

                self.handleEscape(in: field)
                return nil
            }
        }

        private func handleEscape(in field: NSSearchField) {
            if parent.text.isEmpty {
                parent.onEscapeWhileEmpty()
                field.window?.makeFirstResponder(nil)
            } else {
                parent.text = ""
                field.stringValue = ""
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        /// Escape clears the query. Escape on a field that is already empty gives focus back rather
        /// than doing nothing, which is what makes the key feel like it belongs to the window and
        /// not to the control.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }

            // Kept as well as the monitor: this is the path when nothing else claims the key.
            if let field = control as? NSSearchField {
                handleEscape(in: field)
            }
            return true
        }
    }
}
