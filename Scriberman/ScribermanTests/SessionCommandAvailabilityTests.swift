import Foundation
import Testing
@testable import Scriberman

struct SessionCommandAvailabilityTests {
    typealias Command = SessionCommandAvailability.Command
    typealias Selection = SessionCommandAvailability.Selection

    struct Row: CustomTestStringConvertible {
        let name: String
        let selection: Selection
        var isRecordingRunning = false
        var isTranscriptShown = false
        var hasLoadedAudio = false
        var hasFindTarget = true
        let enabled: Set<Command>

        var testDescription: String { name }

        var availability: SessionCommandAvailability {
            SessionCommandAvailability(
                selection: selection,
                isRecordingRunning: isRecordingRunning,
                isTranscriptShown: isTranscriptShown,
                hasLoadedAudio: hasLoadedAudio,
                hasFindTarget: hasFindTarget
            )
        }
    }

    static let rows: [Row] = [
        Row(
            name: "nothing selected",
            selection: .none,
            enabled: [.newSession, .importFile, .startRecording, .find]
        ),
        Row(
            name: "nothing selected, no find target",
            selection: .none,
            hasFindTarget: false,
            enabled: [.newSession, .importFile, .startRecording]
        ),
        Row(
            name: "nothing selected while a recording runs",
            selection: .none,
            isRecordingRunning: true,
            enabled: [.newSession, .importFile, .stopRecording, .find]
        ),
        Row(
            name: "pending session",
            selection: .pending,
            enabled: [.importFile, .startRecording, .find]
        ),
        Row(
            name: "the session being recorded",
            selection: .recording(.recording, isTrimmed: false),
            isRecordingRunning: true,
            enabled: [.importFile, .stopRecording, .find]
        ),
        Row(
            name: "recorded, not transcribed",
            selection: .recording(.recorded, isTrimmed: false),
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause,
                      .transcribe, .reprocess, .tags, .delete]
        ),
        Row(
            name: "recording being transcribed",
            selection: .recording(.transcribing, isTrimmed: false),
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause, .tags, .delete]
        ),
        Row(
            name: "finished recording with transcript and audio",
            selection: .recording(.done, isTrimmed: false),
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause,
                      .reprocess, .copyTranscript, .export, .tags, .transform, .trim, .delete]
        ),
        Row(
            name: "finished recording while another recording runs",
            selection: .recording(.done, isTrimmed: false),
            isRecordingRunning: true,
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .stopRecording, .find, .playPause,
                      .reprocess, .copyTranscript, .export, .tags, .transform, .trim, .delete]
        ),
        Row(
            name: "finished, trimmed recording",
            selection: .recording(.done, isTrimmed: true),
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause,
                      .reprocess, .copyTranscript, .export, .tags, .transform, .restoreOriginal, .delete]
        ),
        Row(
            name: "finished recording, audio not loaded",
            selection: .recording(.done, isTrimmed: false),
            isTranscriptShown: true,
            enabled: [.newSession, .importFile, .startRecording, .find,
                      .copyTranscript, .export, .tags, .transform, .trim, .delete]
        ),
        Row(
            name: "finished recording, transcript not shown",
            selection: .recording(.done, isTrimmed: false),
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause,
                      .reprocess, .tags, .trim, .delete]
        ),
        Row(
            name: "failed recording",
            selection: .recording(.error("failed"), isTrimmed: false),
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause,
                      .reprocess, .tags, .delete]
        ),
        Row(
            name: "recording being reprocessed",
            selection: .recording(.retranscribing, isTrimmed: true),
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause,
                      .copyTranscript, .export, .tags, .transform, .delete]
        ),
        Row(
            name: "imported file being converted",
            selection: .imported(.converting),
            enabled: [.newSession, .importFile, .startRecording, .find, .delete]
        ),
        Row(
            name: "finished imported file",
            selection: .imported(.done),
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.newSession, .importFile, .startRecording, .find, .playPause,
                      .reprocess, .copyTranscript, .export, .transform, .delete]
        ),
    ]

    @Test(arguments: rows)
    func enabledCommands(_ row: Row) {
        #expect(row.availability.enabledCommands == row.enabled)
    }

    @Test(arguments: rows)
    func isEnabledAgreesWithEnabledCommands(_ row: Row) {
        let availability = row.availability
        for command in Command.allCases {
            #expect(availability.isEnabled(command) == row.enabled.contains(command), "\(command)")
        }
    }

    @Test(arguments: rows)
    func stopIsEnabledOnlyWhileARecordingRuns(_ row: Row) {
        let availability = row.availability
        #expect(availability.isEnabled(.stopRecording) == row.isRecordingRunning)
        #expect(availability.isEnabled(.startRecording) == !row.isRecordingRunning)
    }

    @Test
    func noFocusedMainWindowDisablesEveryCommand() {
        let availability = SessionCommandAvailability.noMainWindow
        #expect(availability.enabledCommands.isEmpty)
        for command in Command.allCases {
            #expect(!availability.isEnabled(command), "\(command)")
        }
    }
}

struct SessionMenuTests {
    typealias Command = SessionCommandAvailability.Command
    typealias Selection = SessionCommandAvailability.Selection

    @Test
    func sessionMenuHoldsEverySessionActionInOrder() {
        #expect(SessionCommandAvailability.sessionMenuCommands == [
            .transcribe, .reprocess, .copyTranscript, .export, .tags,
            .transform, .restoreOriginal, .trim, .delete,
        ])
    }

    struct Case: CustomTestStringConvertible {
        let name: String
        let selection: Selection
        var isRecordingRunning = false
        var isTranscriptShown = false
        var hasLoadedAudio = false
        /// The Session menu items enabled for this selection.
        let enabled: Set<Command>

        var testDescription: String { name }

        var availability: SessionCommandAvailability {
            SessionCommandAvailability(
                selection: selection,
                isRecordingRunning: isRecordingRunning,
                isTranscriptShown: isTranscriptShown,
                hasLoadedAudio: hasLoadedAudio,
                hasFindTarget: true
            )
        }
    }

    static let cases: [Case] = [
        Case(name: "no selection", selection: .none, enabled: []),
        Case(name: "pending", selection: .pending, enabled: []),
        Case(
            name: "recording",
            selection: .recording(.recording, isTrimmed: false),
            isRecordingRunning: true,
            hasLoadedAudio: true,
            enabled: []
        ),
        Case(
            name: "recorded, not transcribed",
            selection: .recording(.recorded, isTrimmed: false),
            hasLoadedAudio: true,
            enabled: [.transcribe, .reprocess, .tags, .delete]
        ),
        Case(
            name: "done",
            selection: .recording(.done, isTrimmed: false),
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.reprocess, .copyTranscript, .export, .tags, .transform, .trim, .delete]
        ),
        Case(
            name: "done and trimmed",
            selection: .recording(.done, isTrimmed: true),
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.reprocess, .copyTranscript, .export, .tags, .transform, .restoreOriginal, .delete]
        ),
        Case(
            name: "imported, converting",
            selection: .imported(.converting),
            enabled: [.delete]
        ),
        Case(
            name: "imported, done",
            selection: .imported(.done),
            isTranscriptShown: true,
            hasLoadedAudio: true,
            enabled: [.reprocess, .copyTranscript, .export, .transform, .delete]
        ),
    ]

    @Test(arguments: cases)
    func eachSessionMenuItemFollowsAvailability(_ testCase: Case) {
        let availability = testCase.availability
        for command in SessionCommandAvailability.sessionMenuCommands {
            #expect(availability.isEnabled(command) == testCase.enabled.contains(command), "\(command)")
        }
    }

    @Test
    func noFocusedMainWindowDisablesTheSessionMenu() {
        for command in SessionCommandAvailability.sessionMenuCommands {
            #expect(!SessionCommandAvailability.noMainWindow.isEnabled(command), "\(command)")
        }
    }

    // MARK: - Wiring

    @Test(.tags(.sourceLint))
    func sessionMenuIsACommandMenuInstalledByTheApp() throws {
        let commands = try readSourceFile(relativePathFromTests: "../UI/MainWindowCommands.swift")
        #expect(commands.contains("CommandMenu(\"Session\")"))
        #expect(!commands.contains("struct TrimCommands"))

        let app = try readSourceFile(relativePathFromTests: "../ScribermanApp.swift")
        #expect(app.contains("SessionCommands("))
        #expect(!app.contains("TrimCommands("))
    }

    @Test(.tags(.sourceLint))
    func sessionListHandlesTheDeleteKey() throws {
        let jobsView = try readSourceFile(relativePathFromTests: "../UI/JobsView.swift")
        #expect(jobsView.contains(".onDeleteCommand(perform: onDeleteSelection)"))
    }

    @Test(.tags(.sourceLint))
    func deleteConfirmationIsOwnedByTheWindow() throws {
        let shell = try readSourceFile(relativePathFromTests: "../UI/AppShellView.swift")
        #expect(shell.contains("sessionPendingDeletion"))

        // One confirmation for the toolbar, the menu and the Delete key.
        let detail = try readSourceFile(relativePathFromTests: "../UI/TranscriptDetailView.swift")
        #expect(!detail.contains("showingDeleteConfirmation"))
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent(relativePathFromTests)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
