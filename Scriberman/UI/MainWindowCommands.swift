import SwiftUI

/// What a main window publishes to the menu bar: its selection, which commands it can run, and how
/// to run them. Menus act on the focused window's value only, so with two windows open each acts on
/// its own selection, and with Settings or no main window focused the value is absent.
struct MainWindowCommandContext {
    let selection: JobsViewModel.SessionListItem?
    let availability: SessionCommandAvailability
    let isPlaying: Bool
    /// Editable text holds the window's keyboard, so single-key shortcuts must leave the key to it.
    let isEditingText: Bool
    let actions: MainWindowActions
}

/// The commands a main window runs on its own selection.
struct MainWindowActions {
    let newSession: () -> Void
    let importFile: () -> Void
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let playPause: () -> Void
    let find: () -> Void
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

struct TrimCommands: Commands {
    @Bindable var appState: AppState
    @FocusedValue(\.mainWindow) private var mainWindow: MainWindowCommandContext?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Trim…") {
                appState.sessionToTrim = focusedRecordingSession
            }
            .keyboardShortcut("T", modifiers: [.command, .option])
            .disabled(!mainWindow.availability.isEnabled(.trim))
        }
    }

    private var focusedRecordingSession: RecordingSession? {
        guard case .recording(let session) = mainWindow?.selection else { return nil }
        return session
    }
}
