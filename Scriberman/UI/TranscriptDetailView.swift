import AppKit
import SwiftData
import SwiftUI

struct TranscriptDetailView: View {
    let session: any TranscribableSession
    let onReprocess: (() -> Void)?
    let onCopy: () -> Void
    /// Asks the window to confirm and delete the session.
    let onDelete: () -> Void
    /// Restores a trimmed recording to its pre-trim state; `nil` for sessions that cannot be trimmed.
    let onRestoreOriginal: (() async throws -> Void)?
    let onOpenStudy: (() -> Void)?
    let onOpenTransformation: ((UUID) -> Void)?
    /// Called when a title commit fails to save; the session keeps its previous title.
    let onTitleNotSaved: () -> Void
    /// A Session menu command for this view to carry out; cleared once handled.
    @Binding var commandRequest: DetailCommandRequest?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openSettings) private var openSettings
    @Environment(AppState.self) private var appState
    @State private var showingRestoreConfirmation = false
    @State private var isRestoringOriginal = false
    @State private var restoreErrorMessage: String?
    @State private var editingTitle: String
    @State private var viewModel: TranscriptDetailViewModel
    @FocusState private var titleFocused: Bool
    @State private var isTitleHovering = false

    init(
        session: any TranscribableSession,
        aiProviderService: AIProviderService,
        onReprocess: (() -> Void)?,
        onCopy: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRestoreOriginal: (() async throws -> Void)? = nil,
        onOpenStudy: (() -> Void)?,
        onOpenTransformation: ((UUID) -> Void)?,
        onTitleNotSaved: @escaping () -> Void,
        commandRequest: Binding<DetailCommandRequest?> = .constant(nil)
    ) {
        self.session = session
        self.onReprocess = onReprocess
        self.onCopy = onCopy
        self.onDelete = onDelete
        self.onRestoreOriginal = onRestoreOriginal
        self.onOpenStudy = onOpenStudy
        self.onOpenTransformation = onOpenTransformation
        self.onTitleNotSaved = onTitleNotSaved
        _commandRequest = commandRequest
        _editingTitle = State(initialValue: session.title)
        _viewModel = State(initialValue: TranscriptDetailViewModel(session: session, aiProviderService: aiProviderService))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                aiTransformationSection
                transcriptBody
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if titleFocused {
                titleFocused = false
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let onReprocess {
                    Button {
                        onReprocess()
                    } label: {
                        if viewModel.isReprocessing {
                            Label("Reprocessing", systemImage: "hourglass")
                        } else {
                            Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(!viewModel.canReprocess)
                }

                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                // Tags are a session action, so they live with the others rather than in the
                // header. Only recordings carry tags.
                if let recording = session as? RecordingSession {
                    Menu {
                        TagAssignmentMenuContent(session: recording)
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                }

                transformMenu

                if onRestoreOriginal != nil, (session as? RecordingSession)?.isTrimmed == true {
                    Button {
                        showingRestoreConfirmation = true
                    } label: {
                        Label("Restore Original", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(isRestoringOriginal)
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .restoreOriginalConfirmation(isPresented: $showingRestoreConfirmation) {
            restoreOriginal()
        }
        .task {
            viewModel.loadPrompts()
            viewModel.refreshSelectedTransformation()
        }
        .onChange(of: commandRequest, initial: true) { _, request in
            guard let request else { return }
            commandRequest = nil
            handle(request)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.semibold))
                .focused($titleFocused)
                .onSubmit {
                    commitTitle()
                    titleFocused = false
                }
                .onChange(of: titleFocused) { _, focused in
                    if focused == false {
                        commitTitle()
                    }
                }
                .editableTitleHover(isHovering: $isTitleHovering)
                // Undo and redo change the title outside the field.
                .onChange(of: session.title) { _, title in
                    if titleFocused == false {
                        editingTitle = title
                    }
                }

            Text(headerFactsLine)
                .font(.headline)
                .foregroundStyle(.secondary)

            if let restoreErrorMessage {
                Text(restoreErrorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var headerFactsLine: String {
        var facts = [formattedDate, viewModel.durationText, viewModel.sourcesText]
        if viewModel.wordCount > 0 {
            facts.append("\(viewModel.wordCount) words")
        }
        return facts.joined(separator: " · ")
    }

    private var transformMenu: some View {
        Menu {
            if viewModel.prompts.isEmpty {
                Button("Open AI Settings") {
                    appState.requestedSettingsTab = .ai
                    openSettings()
                }
            } else {
                if viewModel.shouldWarnAboutTranscriptLength {
                    Section {
                        Label("Long transcript — the model may hit context limits", systemImage: "exclamationmark.triangle")
                    }
                }
                ForEach(viewModel.prompts) { prompt in
                    Button(prompt.name) {
                        viewModel.selectedPromptID = prompt.id
                        Task {
                            await viewModel.runTransformation()
                        }
                    }
                }
            }
        } label: {
            Label("Transform", systemImage: "sparkles")
        }
        .disabled(viewModel.isAIEnabled == false || viewModel.isRunningTransformation || viewModel.finalTranscriptText.isEmpty)
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            TranscriptPreviewView(
                blocks: transcriptBlocks,
                onTap: viewModel.displayedTranscript == nil ? nil : onOpenStudy,
                showsAudioSource: viewModel.displayedTranscript?.isSinglePassOfMixedAudio != true
            )
        }
    }

    private var transcriptBlocks: [TranscriptBlock] {
        guard let transcript = viewModel.displayedTranscript else { return [] }
        return TranscriptGrouper.makeBlocks(from: transcript)
    }

    private var aiTransformationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let transformationErrorMessage = viewModel.transformationErrorMessage {
                Text(transformationErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if viewModel.isRunningTransformation {
                SkeletonView()
                    .frame(height: 180)
            } else if let latestTransformation {
                AITransformationPreviewCard(
                    transformation: latestTransformation,
                    onTap: {
                        guard viewModel.availableTransformations.isEmpty == false else { return }
                        onOpenTransformation?(latestTransformation.id)
                    },
                    onCopy: {
                        copyToPasteboard(latestTransformation.resultText)
                    }
                )
            }
        }
    }

    private var latestTransformation: AITransformation? {
        viewModel.availableTransformations.last
    }

    private var formattedDate: String {
        TimeFormatter.displayDateTime(session.createdAt)
    }

    private func handle(_ request: DetailCommandRequest) {
        switch request {
        case .restoreOriginal:
            if onRestoreOriginal != nil, !isRestoringOriginal {
                showingRestoreConfirmation = true
            }
        case .transform(let promptID):
            viewModel.loadPrompts()
            viewModel.selectedPromptID = promptID
            Task {
                await viewModel.runTransformation()
            }
        }
    }

    private func restoreOriginal() {
        guard let onRestoreOriginal else { return }
        isRestoringOriginal = true
        restoreErrorMessage = nil
        Task {
            do {
                try await onRestoreOriginal()
            } catch {
                restoreErrorMessage = error.localizedDescription
            }
            isRestoringOriginal = false
        }
    }

    private func commitTitle() {
        if case .saveFailed = viewModel.commitTitle(editingTitle, context: modelContext, undoManager: undoManager) {
            editingTitle = session.title
            onTitleNotSaved()
        }
    }
}
