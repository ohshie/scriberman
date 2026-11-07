import Foundation

/// Which session commands a main window can run right now. Menus, toolbar buttons and the Delete
/// key read this one value, so they never disagree about what is enabled.
struct SessionCommandAvailability: Equatable {
    enum Command: CaseIterable, Hashable {
        case newSession
        case importFile
        case startRecording
        case stopRecording
        case playPause
        case find
        case transcribe
        case reprocess
        case copyTranscript
        case export
        case rawMarkdown
        case tags
        case transform
        case restoreOriginal
        case splice
        case delete
    }

    /// What the window has selected, reduced to the facts availability depends on.
    enum Selection: Equatable {
        case none
        case pending
        case recording(RecordingStatus, isTrimmed: Bool)
        case imported(RecordingStatus)
    }

    /// The Session menu's items, in menu order.
    static let sessionMenuCommands: [Command] = [
        .transcribe, .reprocess, .copyTranscript, .export, .tags,
        .transform, .restoreOriginal, .splice, .delete,
    ]

    /// Settings or no window is focused: no main-window command may act.
    static let noMainWindow = SessionCommandAvailability(enabledCommands: [])

    let enabledCommands: Set<Command>

    private init(enabledCommands: Set<Command>) {
        self.enabledCommands = enabledCommands
    }

    init(
        selection: Selection,
        isRecordingRunning: Bool,
        isTranscriptShown: Bool,
        hasLoadedAudio: Bool,
        hasFindTarget: Bool,
        isSelectionInActiveWorkspace: Bool,
        hasSpliceCutPoint: Bool = false,
        hasPendingScreenMux: Bool = false,
        isSpliceEditorOpen: Bool = false,
        isApplyingSplice: Bool = false,
        hasSpliceGroup: Bool = false,
        hasBusySpliceMember: Bool = false
    ) {
        var commands: Set<Command> = [.importFile]
        commands.insert(isRecordingRunning ? .stopRecording : .startRecording)
        if hasFindTarget {
            commands.insert(.find)
        }

        let status: RecordingStatus?
        switch selection {
        case .none:
            commands.insert(.newSession)
            status = nil
        case .pending:
            status = nil
        case .recording(let recordingStatus, let isTrimmed):
            status = recordingStatus
            if recordingStatus != .recording {
                commands.insert(.newSession)
                commands.insert(.tags)
            }
            if recordingStatus == .recorded {
                commands.insert(.transcribe)
            }
            if recordingStatus == .done, !isTrimmed, hasSpliceCutPoint,
               !hasPendingScreenMux, isSelectionInActiveWorkspace {
                commands.insert(.splice)
            }
            if isTrimmed || hasSpliceGroup, Self.isSettled(recordingStatus),
               isSelectionInActiveWorkspace, !hasPendingScreenMux, !hasBusySpliceMember {
                commands.insert(.restoreOriginal)
            }
        case .imported(let importedStatus):
            status = importedStatus
            commands.insert(.newSession)
        }

        if let status, status != .recording {
            // The list shows sessions of every workspace, but only the active one's folders can be
            // removed.
            if isSelectionInActiveWorkspace {
                commands.insert(.delete)
            }
            if hasLoadedAudio {
                commands.insert(.playPause)
                if Self.isSettled(status) {
                    commands.insert(.reprocess)
                }
            }
            if isTranscriptShown {
                commands.formUnion([.copyTranscript, .export, .rawMarkdown, .transform])
            }
        }

        if isSpliceEditorOpen {
            commands.subtract([.reprocess, .restoreOriginal, .rawMarkdown, .transform, .delete])
        }
        if isApplyingSplice {
            commands.subtract([.splice, .newSession, .importFile, .startRecording, .playPause, .tags])
        }
        enabledCommands = commands
    }

    func isEnabled(_ command: Command) -> Bool {
        enabledCommands.contains(command)
    }

    /// No recording, conversion or transcription is working on the session.
    static func isSettled(_ status: RecordingStatus) -> Bool {
        switch status {
        case .recorded, .done, .error:
            return true
        case .recording, .converting, .transcribing, .retranscribing:
            return false
        }
    }
}
