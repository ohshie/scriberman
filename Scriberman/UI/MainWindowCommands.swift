import SwiftUI

/// What a main window publishes to the menu bar: its selection, which commands it can run, and how
/// to run them. Menus act on the focused window's value only, so with two windows open each acts on
/// its own selection, and with Settings or no main window focused the value is absent.
struct MainWindowCommandContext {
    let selection: JobsViewModel.SessionListItem?
    let availability: SessionCommandAvailability
    let actions: MainWindowActions
}

/// The commands a main window runs on its own selection.
struct MainWindowActions {
    let newSession: () -> Void
    let importFile: () -> Void
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
