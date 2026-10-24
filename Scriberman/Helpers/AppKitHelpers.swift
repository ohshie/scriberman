import AppKit
import UniformTypeIdentifiers
import Observation

/// Replaces the general pasteboard's contents with `text`. Every copy control goes through here.
func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// Asks where to save a Markdown file, suggesting `suggestedName`.
/// - Returns: the chosen URL, or `nil` when the user cancels.
@MainActor
func presentMarkdownSavePanel(title: String, suggestedName: String) async -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.prompt = "Export"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = suggestedName

    guard await runAttachedToWindow(panel) == .OK else {
        return nil
    }

    return panel.url
}

/// Runs an open or save panel as a sheet on the window in front, so other windows and apps stay
/// usable while it is open. Runs it app-modal only when no window can host the sheet.
@MainActor
func runAttachedToWindow(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
    let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
    guard let window = candidates.first(where: { !($0 is FloatingPanel) && $0.isVisible }) else {
        return panel.runModal()
    }
    return await panel.beginSheetModal(for: window)
}

/// The borderless panel that floats over other apps: the dictation HUD, the idle-session prompt,
/// the calendar suggestion and the recording-start failure.
///
/// Above other windows, on every Space and over full-screen apps, and still shown when the app
/// deactivates. Borderless panels refuse key status by default, which would make their buttons
/// unclickable; accepting it together with `.nonactivatingPanel` lets them work without activating
/// Scriberman or taking focus from the app in front.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    convenience init(size: NSSize, hasShadow: Bool = true) {
        self.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        self.hasShadow = hasShadow
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

/// Whether a window's keyboard focus is in editable text: a text field's editor, a text view being
/// edited. Selectable text that cannot be edited and focused controls do not count.
@MainActor
@Observable
final class TextEditingObserver {
    private(set) var isEditingText = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private weak var window: NSWindow?

    /// Follows `window`'s first responder, replacing any window followed before.
    func observe(_ window: NSWindow?) {
        guard window !== self.window || observation == nil else { return }
        observation?.invalidate()
        self.window = window
        observation = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                self?.update(window.firstResponder)
            }
        }
        update(window?.firstResponder)
    }

    private func update(_ responder: NSResponder?) {
        let isEditing = (responder as? NSTextView)?.isEditable ?? false
        if isEditing != isEditingText {
            isEditingText = isEditing
        }
    }
}
