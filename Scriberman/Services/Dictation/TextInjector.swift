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

/// Inserts dictated text into the focused app via a clipboard-free ladder
/// (design D1): direct Accessibility insertion at the caret, then synthetic
/// Unicode typing. The clipboard is touched only when Accessibility is not
/// granted — where no synthetic input is possible at all — and that outcome
/// is reported so the HUD can disclose it. System calls sit behind injectable
/// seams so ladder selection is unit-testable.
struct TextInjector {
    private static let logger = Logger(subsystem: "Scriberman", category: "TextInjector")

    private let isTrusted: () -> Bool
    private let axInsert: (String) -> Bool
    private let typeOut: (String) -> Bool
    private let copyToClipboard: (String) -> Void

    init(
        isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        axInsert: @escaping (String) -> Bool = TextInjector.insertViaAccessibility,
        typeOut: @escaping (String) -> Bool = TextInjector.typeOutViaKeyboardEvents,
        copyToClipboard: @escaping (String) -> Void = TextInjector.writeToClipboard
    ) {
        self.isTrusted = isTrusted
        self.axInsert = axInsert
        self.typeOut = typeOut
        self.copyToClipboard = copyToClipboard
    }

    var isAccessibilityGranted: Bool {
        isTrusted()
    }

    func insert(_ text: String) -> InsertionOutcome {
        guard !text.isEmpty else { return .failed }

        guard isTrusted() else {
            Self.logger.info("Dictation insertion: Accessibility not granted, using disclosed clipboard fallback")
            copyToClipboard(text)
            return .copiedToClipboard
        }

        if axInsert(text) {
            Self.logger.info("Dictation inserted transcript at the caret via Accessibility")
            return .insertedDirectly
        }

        if typeOut(text) {
            Self.logger.info("Dictation typed transcript via synthetic Unicode events")
            return .typedOut
        }

        Self.logger.error("Dictation insertion failed on every rung")
        return .failed
    }

    // MARK: - Rung 1: direct Accessibility insertion

    static func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedValue: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusedStatus == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            logger.info("AX insertion unavailable: no focused UI element")
            return false
        }
        let element = unsafeBitCast(focusedValue, to: AXUIElement.self)

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else {
            logger.info("AX insertion unavailable: focused element does not accept selected-text replacement")
            return false
        }

        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return status == .success
    }

    // MARK: - Rung 2: synthetic Unicode typing (no clipboard)

    static func typeOutViaKeyboardEvents(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            logger.info("Type-out unavailable: failed to create event source")
            return false
        }

        for chunk in UnicodeTypeOutChunker.chunks(for: text) {
            var units = Array(chunk.utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                logger.info("Type-out aborted: failed to create keyboard events")
                return false
            }
            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: - Last resort: disclosed clipboard write

    static func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
