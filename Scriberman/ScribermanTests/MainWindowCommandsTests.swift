import AppKit
import SwiftUI
import Testing
@testable import Scriberman

struct ControlsCommandsTests {
    @Test
    func playPauseIsTitledForWhatItWillDo() {
        #expect(ControlsCommands.playPauseTitle(isPlaying: false) == "Play")
        #expect(ControlsCommands.playPauseTitle(isPlaying: true) == "Pause")
    }

    /// A bare Space menu shortcut takes the key from a text field even while the item is disabled,
    /// so the item carries Space only while it can act and no text is being edited.
    @Test(arguments: [
        (isEnabled: true, isEditingText: false, hasShortcut: true),
        (isEnabled: true, isEditingText: true, hasShortcut: false),
        (isEnabled: false, isEditingText: false, hasShortcut: false),
        (isEnabled: false, isEditingText: true, hasShortcut: false),
    ])
    func playPauseCarriesSpaceOnlyWhenItCanActOutsideText(
        row: (isEnabled: Bool, isEditingText: Bool, hasShortcut: Bool)
    ) {
        let shortcut = ControlsCommands.playPauseShortcut(isEnabled: row.isEnabled, isEditingText: row.isEditingText)
        #expect((shortcut != nil) == row.hasShortcut)
        if let shortcut {
            #expect(shortcut.key == .space)
            #expect(shortcut.modifiers.isEmpty)
        }
    }

    @Test
    func rawMarkdownIsTitledForWhatItWillDo() {
        #expect(RawMarkdownCommands.title(isShown: false) == "Show Raw Markdown")
        #expect(RawMarkdownCommands.title(isShown: true) == "Hide Raw Markdown")
    }

    @Test
    func findOpensTheTranscriptFindBarOnlyInTheTranscriptView() {
        #expect(FindDestination(isTranscriptViewShown: true) == .transcriptFindBar)
        #expect(FindDestination(isTranscriptViewShown: false) == .sessionSearch)
    }
}

/// The menu bar the test host app builds. Nothing is loaded for playback while tests run.
@MainActor
struct ControlsAndFindMenuBarTests {
    private func topMenu(_ title: String) async throws -> NSMenu {
        for _ in 0..<100 {
            if let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu {
                return menu
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MenuNotFound(title: title)
    }

    private struct MenuNotFound: Error {
        let title: String
    }

    @Test
    func theControlsMenuListsRecordingAndPlayback() async throws {
        let controls = try await topMenu("Controls")
        let start = try #require(controls.items.first { $0.title == "Start Recording" })
        let stop = try #require(controls.items.first { $0.title == "Stop Recording" })
        let play = try #require(controls.items.first { $0.title == "Play" })

        #expect(start.keyEquivalent == "r")
        #expect(start.keyEquivalentModifierMask == [.command, .shift])
        #expect(stop.keyEquivalent == "e")
        #expect(stop.keyEquivalentModifierMask == [.command, .shift])
        // Nothing can play, so Space is left to whatever has focus.
        #expect(play.keyEquivalent.isEmpty)
    }

    @Test
    func findIsInTheEditMenu() async throws {
        let edit = try await topMenu("Edit")
        let find = try #require(edit.items.first { $0.title == "Find" })

        #expect(find.keyEquivalent == "f")
        #expect(find.keyEquivalentModifierMask == .command)
    }

    @Test
    func rawMarkdownIsInTheViewMenu() async throws {
        let view = try await topMenu("View")
        let rawMarkdown = try #require(view.items.first { $0.title == "Show Raw Markdown" })

        #expect(rawMarkdown.keyEquivalent == "m")
        #expect(rawMarkdown.keyEquivalentModifierMask == [.command, .shift])
    }
}

@MainActor
struct TextEditingObserverTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    @Test
    func editingATextFieldCountsAsEditingText() {
        let window = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        window.contentView?.addSubview(field)
        let observer = TextEditingObserver()
        observer.observe(window)

        window.makeFirstResponder(field)
        #expect(observer.isEditingText)

        window.makeFirstResponder(nil)
        #expect(!observer.isEditingText)
    }

    @Test
    func selectableTextThatCannotBeEditedDoesNotCount() {
        let window = makeWindow()
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        textView.isEditable = false
        textView.isSelectable = true
        window.contentView?.addSubview(textView)
        let observer = TextEditingObserver()
        observer.observe(window)

        window.makeFirstResponder(textView)
        #expect(!observer.isEditingText)

        textView.isEditable = true
        window.makeFirstResponder(nil)
        window.makeFirstResponder(textView)
        #expect(observer.isEditingText)
    }

    @Test
    func aFocusedButtonDoesNotCount() {
        let window = makeWindow()
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        window.contentView?.addSubview(button)
        let observer = TextEditingObserver()
        observer.observe(window)

        window.makeFirstResponder(button)
        #expect(!observer.isEditingText)
    }

    @Test
    func observingAnotherWindowFollowsThatWindow() {
        let first = makeWindow()
        let second = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        first.contentView?.addSubview(field)
        let observer = TextEditingObserver()
        observer.observe(first)
        first.makeFirstResponder(field)
        #expect(observer.isEditingText)

        observer.observe(second)
        #expect(!observer.isEditingText)
        first.makeFirstResponder(nil)
        first.makeFirstResponder(field)
        #expect(!observer.isEditingText)
    }
}

/// The menu commands replace the invisible buttons and the notification that carried ⌘F and Space.
struct ControlsAndFindCommandsSourceTests {
    @Test(.tags(.sourceLint))
    func theControlsMenuAndFindAreMenuCommands() throws {
        let commands = try readSourceFile(relativePathFromTests: "../UI/MainWindowCommands.swift")
        let app = try readSourceFile(relativePathFromTests: "../ScribermanApp.swift")

        #expect(commands.contains("CommandMenu(\"Controls\")"))
        #expect(commands.contains("Button(\"Start Recording\")"))
        #expect(commands.contains(".keyboardShortcut(\"r\", modifiers: [.command, .shift])"))
        #expect(commands.contains("Button(\"Stop Recording\")"))
        #expect(commands.contains(".keyboardShortcut(\"e\", modifiers: [.command, .shift])"))
        #expect(commands.contains("CommandGroup(replacing: .textEditing)"))
        #expect(commands.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        #expect(app.contains("ControlsCommands()"))
        #expect(app.contains("FindCommands()"))
    }

    @Test(.tags(.sourceLint))
    func theHiddenShortcutButtonsAndTheFindNotificationAreGone() throws {
        let shell = try readSourceFile(relativePathFromTests: "../UI/AppShellView.swift")
        let player = try readSourceFile(relativePathFromTests: "../UI/AudioPlayerBar.swift")
        let detail = try readSourceFile(relativePathFromTests: "../UI/TranscriptDetailView.swift")

        #expect(!shell.contains(".keyboardShortcut("))
        #expect(!shell.contains(".opacity(0.001)"))
        #expect(!player.contains(".keyboardShortcut("))
        #expect(!player.contains("EmptyView()"))
        for source in [shell, player, detail] {
            #expect(!source.contains("transcriptSearchRequested"))
        }
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent(relativePathFromTests),
            encoding: .utf8
        )
    }
}
