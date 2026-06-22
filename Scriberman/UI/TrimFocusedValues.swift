import SwiftUI

private struct TrimTargetSessionKey: FocusedValueKey {
    typealias Value = RecordingSession
}

extension FocusedValues {
    var trimTargetSession: RecordingSession? {
        get { self[TrimTargetSessionKey.self] }
        set { self[TrimTargetSessionKey.self] = newValue }
    }
}

struct TrimCommands: Commands {
    @Bindable var appState: AppState
    @FocusedValue(\.trimTargetSession) private var focusedSession: RecordingSession?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Button("Trim…") {
                appState.sessionToTrim = focusedSession
            }
            .keyboardShortcut("T", modifiers: [.command, .option])
            .disabled(!canTrim)
        }
    }

    private var canTrim: Bool {
        guard let session = focusedSession else { return false }
        return session.status == .done && !session.isTrimmed
    }
}
