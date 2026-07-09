import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

enum InsertionOutcome: Equatable {
    case insertedDirectly
    case typedOut
    case copiedToClipboard
    case failed
}

struct TextInjector {
    private let logger = Logger(subsystem: "Scriberman", category: "TextInjector")

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    // Inserts text into the focused app, reporting what actually happened.
    // Synthetic input is impossible without Accessibility trust, so the
    // untrusted path goes straight to the disclosed clipboard fallback.
    func insert(_ text: String) -> InsertionOutcome {
        guard !text.isEmpty else { return .failed }
        logger.info("Dictation insertion starting (accessibility trusted: \(self.isAccessibilityGranted, privacy: .public))")
        guard isAccessibilityGranted else {
            writeToClipboard(text)
            return .copiedToClipboard
        }
        if injectViaSimulatedPaste(text) {
            return .insertedDirectly
        }
        writeToClipboard(text)
        return .copiedToClipboard
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
