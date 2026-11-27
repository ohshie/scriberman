import AppKit
import SwiftData
import SwiftUI

/// What a main window publishes to the menu bar: its selection, which commands it can run, and how
/// to run them. Menus act on the focused window's value only; with Settings or no main window
/// focused the value is absent.
struct MainWindowCommandContext {
    let selection: JobsViewModel.SessionListItem?
    let availability: SessionCommandAvailability
    let isPlaying: Bool
    /// The running recording is paused, so the pause item resumes it.
    var isRecordingPaused = false
    /// Editable text holds the window's keyboard, so single-key shortcuts must leave the key to it.
    let isEditingText: Bool
    /// The transcript shows as Markdown text rather than passages.
    let isRawMarkdownShown: Bool
    let actions: MainWindowActions
    /// The window's store context, for the Tags submenu that edits the selection's tags in place.
    let modelContext: ModelContext
    var spliceEditor: SpliceEditorViewModel? = nil
    var isApplyingSessionEdit = false
}

/// The commands a main window runs on its own selection.
struct MainWindowActions {
    let newSession: () -> Void
    let importFile: () -> Void
    let transcribe: () -> Void
    let reprocess: () -> Void
    let copyTranscript: () -> Void
    let export: () -> Void
    let transform: (_ promptID: UUID) -> Void
    let restoreOriginal: () -> Void
    let splice: () -> Void
    /// Asks for the window's delete confirmation; nothing is deleted until it is confirmed.
    let delete: () -> Void
    let startRecording: () -> Void
    let stopRecording: () -> Void
    /// Pauses the running recording, or resumes the paused one.
    let pauseResumeRecording: () -> Void
    let playPause: () -> Void
    let find: () -> Void
    let toggleRawMarkdown: () -> Void
}

/// A Session menu command the detail view carries out, because it shows the command's
/// confirmation, progress or result.
enum DetailCommandRequest: Equatable {
    case restoreOriginal
    case transform(promptID: UUID)
}

/// What Find searches: the open transcript, or the session list when no transcript is open.
enum FindDestination: Equatable {
    case transcriptFindBar
    case sessionSearch

    init(isTranscriptViewShown: Bool) {
        self = isTranscriptViewShown ? .transcriptFindBar : .sessionSearch
    }
}

private struct MainWindowCommandContextKey: FocusedValueKey {
    typealias Value = MainWindowCommandContext
}

extension FocusedValues {
    var mainWindow: MainWindowCommandContext? {
        get { self[MainWindowCommandContextKey.self] }
        set { self[MainWindowCommandContextKey.self] = newValue }
    }
}

extension Optional where Wrapped == MainWindowCommandContext {
    /// A missing context means no main window is focused, so every command is disabled.
    var availability: SessionCommandAvailability {
        self?.availability ?? .noMainWindow
    }
}

struct FileCommands: Commands {
    @FocusedValue(\.mainWindow) private var mainWindow: MainWindowCommandContext?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                mainWindow?.actions.newSession()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!mainWindow.availability.isEnabled(.newSession))

            Button("Import File…") {
                mainWindow?.actions.importFile()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!mainWindow.availability.isEnabled(.importFile))
        }
    }
}

struct ControlsCommands: Commands {
    @FocusedValue(\.mainWindow) private var mainWindow: MainWindowCommandContext?

    var body: some Commands {
        CommandMenu("Controls") {
            Button("Start Recording") {
                mainWindow?.actions.startRecording()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!mainWindow.availability.isEnabled(.startRecording))

            Button(Self.pauseResumeTitle(isPaused: mainWindow?.isRecordingPaused ?? false)) {
                mainWindow?.actions.pauseResumeRecording()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!mainWindow.availability.isEnabled(.pauseResumeRecording))

            Button("Stop Recording") {
                mainWindow?.actions.stopRecording()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!mainWindow.availability.isEnabled(.stopRecording))

            Divider()

            Button(Self.playPauseTitle(isPlaying: mainWindow?.isPlaying ?? false)) {
                mainWindow?.actions.playPause()
            }
            .keyboardShortcut(Self.playPauseShortcut(
                isEnabled: mainWindow.availability.isEnabled(.playPause),
                isEditingText: mainWindow?.isEditingText ?? false
            ))
            .disabled(!mainWindow.availability.isEnabled(.playPause))
        }
    }

    /// The pause/resume item's title, also used by the menu-bar item.
    static func pauseResumeTitle(isPaused: Bool) -> String {
        isPaused ? "Resume Recording" : "Pause Recording"
    }

    static func playPauseTitle(isPlaying: Bool) -> String {
        isPlaying ? "Pause" : "Play"
    }

    /// A bare Space menu shortcut takes the key before a text field or the focused control sees it,
    /// and does so even while the item is disabled. So the item carries Space only while it can act
    /// and no text is being edited; otherwise Space types, or reaches whatever has focus.
    static func playPauseShortcut(isEnabled: Bool, isEditingText: Bool) -> KeyboardShortcut? {
        guard isEnabled, !isEditingText else { return nil }
        return KeyboardShortcut(.space, modifiers: [])
    }
}

struct FindCommands: Commands {
    @FocusedValue(\.mainWindow) private var mainWindow: MainWindowCommandContext?

    var body: some Commands {
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                mainWindow?.actions.find()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!mainWindow.availability.isEnabled(.find))
        }
    }
}

struct RawMarkdownCommands: Commands {
    @FocusedValue(\.mainWindow) private var mainWindow: MainWindowCommandContext?

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(Self.title(isShown: mainWindow?.isRawMarkdownShown ?? false)) {
                mainWindow?.actions.toggleRawMarkdown()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(!mainWindow.availability.isEnabled(.rawMarkdown))
        }
    }

    static func title(isShown: Bool) -> String {
        isShown ? "Hide Raw Markdown" : "Show Raw Markdown"
    }
}

struct SessionCommands: Commands {
    @Bindable var appState: AppState
    @FocusedValue(\.mainWindow) private var mainWindow: MainWindowCommandContext?
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandMenu("Session") {
            ForEach(SessionCommandAvailability.sessionMenuCommands, id: \.self) { command in
                item(for: command)
                    .disabled(!mainWindow.availability.isEnabled(command))
            }
        }
    }

    @ViewBuilder
    private func item(for command: SessionCommandAvailability.Command) -> some View {
        switch command {
        case .transcribe:
            Button("Transcribe") { mainWindow?.actions.transcribe() }
        case .reprocess:
            Button("Reprocess") { mainWindow?.actions.reprocess() }
        case .copyTranscript:
            Button("Copy Transcript") { mainWindow?.actions.copyTranscript() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        case .export:
            Button("Export…") { mainWindow?.actions.export() }
        case .tags:
            Menu("Tags") {
                if let mainWindow, case .recording(let session) = mainWindow.selection {
                    TagAssignmentMenuContent(session: session)
                        .environment(\.modelContext, mainWindow.modelContext)
                        .environment(appState)
                }
            }
        case .transform:
            Menu("Transform") {
                transformItems
            }
        case .restoreOriginal:
            Button("Restore Original") { mainWindow?.actions.restoreOriginal() }
        case .splice:
            Toggle("Splice…", isOn: Binding(
                get: { mainWindow?.spliceEditor != nil },
                set: { _ in mainWindow?.actions.splice() }
            ))
            .keyboardShortcut("s", modifiers: [.command, .option])
        case .delete:
            Button("Delete") { mainWindow?.actions.delete() }
                .keyboardShortcut(.delete, modifiers: .command)
        default:
            EmptyView()
        }
    }

    /// The same choices as the detail toolbar's Transform menu.
    @ViewBuilder
    private var transformItems: some View {
        let prompts = TranscriptDetailViewModel.sortedPrompts(AIPromptStore().loadPrompts())
        if prompts.isEmpty {
            Button("Open AI Settings") {
                appState.requestedSettingsTab = .ai
                openSettings()
            }
        } else {
            ForEach(prompts) { prompt in
                Button(prompt.name) { mainWindow?.actions.transform(prompt.id) }
            }
        }
    }
}

/// Editor history is separate; text fields and the rest of the app use responder-chain undo.
struct SpliceUndoCommands: Commands {
    @FocusedValue(\.mainWindow) private var mainWindow: MainWindowCommandContext?
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            if let editor = mainWindow?.spliceEditor, mainWindow?.isEditingText != true {
                Button(editor.undoManager.undoMenuItemTitle, action: editor.undo)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!editor.canUndo)
                Button(editor.undoManager.redoMenuItemTitle, action: editor.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.canRedo)
            } else {
                // Replacing the group removes the system items, so these mirror them: the title
                // names the action and the item is disabled when there is nothing to undo.
                let state = UndoMenuState.shared
                Button(state.undoTitle) { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndo || mainWindow?.isApplyingSessionEdit == true)
                Button(state.redoTitle) { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!state.canRedo || mainWindow?.isApplyingSessionEdit == true)
            }
        }
    }
}

/// The key window's undo state, as the system Undo and Redo items would show it. Refreshed on
/// undo-manager and key-window changes, and on window updates so a focus change into or out of a
/// text field is picked up.
@MainActor
@Observable
final class UndoMenuState {
    static let shared = UndoMenuState(observing: .default)

    private(set) var undoTitle = "Undo"
    private(set) var redoTitle = "Redo"
    private(set) var canUndo = false
    private(set) var canRedo = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(observing center: NotificationCenter?) {
        guard let center else { return }
        let names: [Notification.Name] = [
            .NSUndoManagerCheckpoint, .NSUndoManagerDidUndoChange,
            .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didUpdateNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        refresh(from: NSApp.keyWindow?.firstResponder?.undoManager)
    }

    /// Assigns only changed values, so the frequent window-update refresh rebuilds no menus.
    func refresh(from manager: UndoManager?) {
        let undo = manager?.undoMenuItemTitle ?? "Undo"
        let redo = manager?.redoMenuItemTitle ?? "Redo"
        let canUndo = manager?.canUndo ?? false
        let canRedo = manager?.canRedo ?? false
        if undoTitle != undo { undoTitle = undo }
        if redoTitle != redo { redoTitle = redo }
        if self.canUndo != canUndo { self.canUndo = canUndo }
        if self.canRedo != canRedo { self.canRedo = canRedo }
    }
}
