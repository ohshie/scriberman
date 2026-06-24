import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

struct TextInjector {
    private let logger = Logger(subsystem: "Scriberman", category: "TextInjector")

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    // Appends text to the currently focused element via AX, falling back to the clipboard.
    func inject(_ text: String) {
        guard !text.isEmpty else { return }
        logger.info("Dictation injection starting (accessibility trusted: \(self.isAccessibilityGranted, privacy: .public))")
        if injectViaSimulatedPaste(text) {
            return
        }
        writeToClipboard(text)
    }

    @discardableResult
    private func injectViaSimulatedPaste(_ text: String) -> Bool {
        writeToClipboard(text)

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else {
            logger.info("Accessibility paste injection unavailable: failed to create keyboard events")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.info("Dictation pasted transcript into focused application")
        return true
    }

    private func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.info("Dictation wrote transcript to clipboard fallback")
    }
}
