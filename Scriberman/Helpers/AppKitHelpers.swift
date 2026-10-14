import AppKit
import UniformTypeIdentifiers

/// Replaces the general pasteboard's contents with `text`. Every copy control goes through here.
func copyToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

/// Asks where to save a Markdown file, suggesting `suggestedName`.
/// - Returns: the chosen URL, or `nil` when the user cancels.
@MainActor
func presentMarkdownSavePanel(title: String, suggestedName: String) -> URL? {
    let panel = NSSavePanel()
    panel.title = title
    panel.prompt = "Export"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = suggestedName

    guard panel.runModal() == .OK else {
        return nil
    }

    return panel.url
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
