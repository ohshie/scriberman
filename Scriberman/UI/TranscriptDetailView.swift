import AppKit
import SwiftData
import SwiftUI

@MainActor
protocol TranscriptPlaybackControlling: AnyObject {
    func seek(to seconds: Double)
    func play()
}

extension AudioPlayerViewModel: TranscriptPlaybackControlling {}

/// A finished or imported session: the editable title and facts line, the AI result, then the whole
/// transcript with playback, find and speaker edits in place.
struct TranscriptDetailView: View {
    let session: any TranscribableSession
    let audioPlayerViewModel: AudioPlayerViewModel
    @Binding var autoScrollEnabled: Bool
    /// The transcript the caller passed in, kept to notice when the session's displayed
    /// transcript changes while the view is open (a retranscription or a restore).
    private let inputTranscript: Transcript?
    /// A search to apply on opening, or `nil` to open with an empty find bar and no match selected.
    let searchSeed: TranscriptSearchSeed?
    /// Bumped by the window's Find command to open the find bar.
    let findRequest: Int
    /// Shows the transcript as its Markdown text instead of passages.
    let isRawMarkdownShown: Bool
    let onCopy: () -> Void
    let onExport: () -> Void
    /// Asks the window to confirm and delete the session; `nil` while it cannot be deleted.
    let onDelete: (() -> Void)?
    /// Restores a trimmed recording to its pre-trim state; `nil` for sessions that cannot be trimmed.
    let onRestoreOriginal: (() async throws -> Void)?
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
    @State private var scrollTargetID: UUID?
    /// The block whose speaker is being renamed inline.
    @State private var renamingBlockID: UUID?
    @State private var isSpeakerListShown = false

    init(
        session: any TranscribableSession,
        aiProviderService: AIProviderService,
        audioPlayerViewModel: AudioPlayerViewModel,
        autoScrollEnabled: Binding<Bool>,
        transcript: Transcript?,
        store: SpeakerEmbeddingStore? = nil,
        sessionJobs: SessionJobs,
        searchSeed: TranscriptSearchSeed? = nil,
        findRequest: Int = 0,
        isRawMarkdownShown: Bool = false,
        onCopy: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        onRestoreOriginal: (() async throws -> Void)? = nil,
        onOpenTransformation: ((UUID) -> Void)?,
        onTitleNotSaved: @escaping () -> Void,
        commandRequest: Binding<DetailCommandRequest?> = .constant(nil)
    ) {
        self.session = session
        self.audioPlayerViewModel = audioPlayerViewModel
        _autoScrollEnabled = autoScrollEnabled
        self.inputTranscript = transcript
        self.searchSeed = searchSeed
        self.findRequest = findRequest
        self.isRawMarkdownShown = isRawMarkdownShown
        self.onCopy = onCopy
        self.onExport = onExport
        self.onDelete = onDelete
        self.onRestoreOriginal = onRestoreOriginal
        self.onOpenTransformation = onOpenTransformation
        self.onTitleNotSaved = onTitleNotSaved
        _commandRequest = commandRequest
        _editingTitle = State(initialValue: session.title)
        _viewModel = State(initialValue: TranscriptDetailViewModel(
            session: session,
            aiProviderService: aiProviderService,
            store: store,
            transcript: transcript,
            sessionJobs: sessionJobs
        ))
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
        .scrollPosition(id: $scrollTargetID)
        .contentShape(Rectangle())
        .onTapGesture {
            if titleFocused {
                titleFocused = false
            }
        }
        .onChange(of: activeBlock?.id) {
            guard autoScrollEnabled else {
                return
            }
            scrollTargetID = activeBlock?.id
        }
        // Keyed on the seed, so opening the same match again re-applies it: selecting a result
        // whose session is already open changes no binding the view could otherwise notice.
        .task(id: searchSeed) {
            applySearchSeed()
        }
        // A retranscription or restore changes the session's displayed transcript while the view
        // is open. The view's own speaker rename writes the same value back, so this is a no-op then.
        .onChange(of: inputTranscript) {
            viewModel.refreshTranscript()
        }
        .onChange(of: searchState.query) {
            viewModel.updateSearch()
        }
        .onChange(of: searchState.currentMatch?.blockID) {
            scrollTargetID = searchState.currentMatch?.blockID
        }
        .onChange(of: isSearchVisible) {
            if isSearchVisible {
                autoScrollEnabled = false
            }
        }
        .onChange(of: findRequest) {
            presentSearch()
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .interacting {
                autoScrollEnabled = false
            }
        }
        .safeAreaBar(edge: .bottom) {
            if isSearchVisible {
                TranscriptFindBar(searchState: searchState) {
                    dismissSearch()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Hard style while the find bar is shown: the automatic edge effect lit the bar up under the
        // pointer. Without it the edge keeps the automatic style the player bar uses.
        .scrollEdgeEffectStyle(isSearchVisible ? .hard : nil, for: .bottom)
        // A permanent frosted band under the toolbar, as in Photos. With the automatic style the
        // band appeared only under the pointer, so scrolled text showed through the toolbar.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // Grouped by what each acts on, apart from the window's New Session. Reprocess and Restore
        // Original are in the Session menu.
        .toolbar {
            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    onCopy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy")
                .disabled(!hasTranscript)

                Button {
                    onExport()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export")
                .disabled(!hasTranscript)

                Button {
                    presentSearch()
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .help("Find")
                .disabled(!hasTranscript)

                speakersButton
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                transformMenu
            }

            // Only recordings carry tags.
            if let recording = session as? RecordingSession {
                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        TagAssignmentMenuContent(session: recording)
                    } label: {
                        Label("Tags", systemImage: "tag")
                    }
                    .help("Tags")
                }
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    onDelete?()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .help("Delete")
                .disabled(onDelete == nil)
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
        .help("Transform")
        .disabled(viewModel.isAIEnabled == false || viewModel.isRunningTransformation || viewModel.finalTranscriptText.isEmpty)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if isRawMarkdownShown {
            Text(viewModel.rawMarkdown)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if blocks.isEmpty {
            Text("No transcript available.")
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(blocks) { block in
                    TranscriptBlockView(
                        block: block,
                        isActive: activeBlock?.id == block.id,
                        searchRanges: searchState.ranges(in: block),
                        activeSearchRange: searchState.activeRange(in: block),
                        onTap: {
                            if renamingBlockID != block.id {
                                renamingBlockID = nil
                            }
                            TranscriptDetailViewModel.seekAndPlay(block: block, player: audioPlayerViewModel)
                        },
                        speakerEditing: speakerEditing(for: block),
                        showsAudioSource: viewModel.shownTranscript?.isSinglePassOfMixedAudio != true
                    )
                    .zIndex(renamingBlockID == block.id ? 1 : 0)
                }
            }
        }
    }

    private var speakersButton: some View {
        Button {
            viewModel.loadProfiles()
            isSpeakerListShown.toggle()
        } label: {
            Label("Speakers", systemImage: "person.2")
        }
        .help("Speakers")
        .accessibilityLabel("Speakers")
        .disabled(!hasTranscript)
        .popover(isPresented: $isSpeakerListShown, arrowEdge: .bottom) {
            if let transcript = viewModel.shownTranscript {
                SessionSpeakerListView(
                    transcript: transcript,
                    profiles: viewModel.profiles,
                    onRename: { id, name in viewModel.renameSpeaker(id: id, to: name, undoManager: undoManager) },
                    onMerge: { id, targetID in viewModel.mergeSpeaker(id, into: targetID, undoManager: undoManager) },
                    onReset: { id in viewModel.resetSpeaker(id, undoManager: undoManager) }
                )
            }
        }
    }

    private var hasTranscript: Bool {
        viewModel.shownTranscript != nil
    }

    private var blocks: [TranscriptBlock] {
        viewModel.blocks
    }

    private var searchState: TranscriptSearchState {
        viewModel.searchState
    }

    private var isSearchVisible: Bool {
        viewModel.isSearchVisible
    }

    private var activeBlock: TranscriptBlock? {
        viewModel.activeBlock(at: audioPlayerViewModel.currentTime)
    }

    private func speakerEditing(for block: TranscriptBlock) -> TranscriptBlockView.SpeakerEditing {
        TranscriptBlockView.SpeakerEditing(
            isRenaming: renamingBlockID == block.id,
            profiles: viewModel.profiles,
            otherSpeakers: viewModel.shownTranscript.map {
                TranscriptGrouper.displaySpeakers(of: $0).filter { $0.id != block.speaker.id }
            } ?? [],
            onBeginRename: {
                renamingBlockID = block.id
                viewModel.loadProfiles()
            },
            onEndRename: {
                if renamingBlockID == block.id {
                    renamingBlockID = nil
                }
            },
            onRename: { name in
                viewModel.renameSpeaker(id: block.speaker.id, to: name, undoManager: undoManager)
            },
            onAssign: { speakerID in
                viewModel.assign(block, to: speakerID, undoManager: undoManager)
            }
        )
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

    /// Opens the find bar on the seeded query with the seeded match selected, and scrolls to it.
    ///
    /// Auto-scroll is turned off for the same reason presenting the find bar does: playback
    /// position must not drag the view away from the match the user came here to read.
    private func applySearchSeed() {
        guard viewModel.applySearchSeed(searchSeed) else { return }

        autoScrollEnabled = false
        scrollTargetID = searchState.currentMatch?.blockID
    }

    private func presentSearch() {
        withAnimation {
            viewModel.presentSearch()
        }
    }

    private func dismissSearch() {
        viewModel.clearSearch()
        withAnimation {
            viewModel.isSearchVisible = false
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
