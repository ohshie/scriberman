import SwiftData
import SwiftUI

/// What a main window publishes to the menu bar: its selection, which commands it can run, and how
/// to run them. Menus act on the focused window's value only, so with two windows open each acts on
/// its own selection, and with Settings or no main window focused the value is absent.
struct MainWindowCommandContext {
    let selection: JobsViewModel.SessionListItem?
    let availability: SessionCommandAvailability
    let actions: MainWindowActions
    /// The window's store context, for the Tags submenu that edits the selection's tags in place.
    let modelContext: ModelContext
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
    let trim: () -> Void
    /// Asks for the window's delete confirmation; nothing is deleted until it is confirmed.
    let delete: () -> Void
}

/// A Session menu command the detail view carries out, because it shows the command's
/// confirmation, progress or result.
enum DetailCommandRequest: Equatable {
    case restoreOriginal
    case transform(promptID: UUID)
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
        case .trim:
            Button("Trim…") { mainWindow?.actions.trim() }
                .keyboardShortcut("T", modifiers: [.command, .option])
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
