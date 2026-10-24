import SwiftUI

@MainActor
protocol TranscriptPlaybackControlling: AnyObject {
    func seek(to seconds: Double)
    func play()
}

extension AudioPlayerViewModel: TranscriptPlaybackControlling {}

/// A search to open the study view with: the query typed in the session list, and the block whose
/// match was selected.
///
/// `token` makes two otherwise identical seeds different values. Opening the same match twice — the
/// user clicking the result again — has to move the view again, and a seed that compared equal to
/// the one already applied would do nothing.
struct TranscriptStudySearchSeed: Equatable {
    let query: String
    let blockID: UUID?
    let token: UUID

    init(query: String, blockID: UUID?, token: UUID = UUID()) {
        self.query = query
        self.blockID = blockID
        self.token = token
    }
}

struct TranscriptStudyView: View {
    let session: any TranscribableSession
    let audioPlayerViewModel: AudioPlayerViewModel
    @Binding var autoScrollEnabled: Bool
    @State private var viewModel: TranscriptDetailViewModel
    /// The transcript the caller passed in, kept to notice when the session's displayed
    /// transcript changes while the view is open (a retranscription or a restore).
    private let inputTranscript: Transcript
    let showRawMarkdownToggle: Bool
    /// A search to apply on opening, or `nil` to open as the view always has — empty find bar, no
    /// match selected.
    let searchSeed: TranscriptStudySearchSeed?

    @State private var showRawMarkdown = false
    @State private var scrollTargetID: UUID?
    /// The block whose speaker is being renamed inline.
    @State private var renamingBlockID: UUID?
    @State private var isSpeakerListShown = false
    @Environment(\.undoManager) private var undoManager

    init(
        session: any TranscribableSession,
        aiProviderService: AIProviderService,
        audioPlayerViewModel: AudioPlayerViewModel,
        autoScrollEnabled: Binding<Bool>,
        transcript: Transcript,
        store: SpeakerEmbeddingStore? = nil,
        showRawMarkdownToggle: Bool = true,
        searchSeed: TranscriptStudySearchSeed? = nil
    ) {
        self.session = session
        self.audioPlayerViewModel = audioPlayerViewModel
        self._autoScrollEnabled = autoScrollEnabled
        self._viewModel = State(initialValue: TranscriptDetailViewModel(
            session: session,
            aiProviderService: aiProviderService,
            store: store,
            transcript: transcript
        ))
        self.inputTranscript = transcript
        self.showRawMarkdownToggle = showRawMarkdownToggle
        self.searchSeed = searchSeed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showRawMarkdown {
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
                                showsAudioSource: transcript.isSinglePassOfMixedAudio != true
                            )
                            .zIndex(renamingBlockID == block.id ? 1 : 0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollPosition(id: $scrollTargetID)
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
        .onReceive(NotificationCenter.default.publisher(for: .transcriptSearchRequested)) { _ in
            presentSearch()
        }
        .onScrollPhaseChange { _, newPhase in
            if newPhase == .interacting {
                autoScrollEnabled = false
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.loadProfiles()
                    isSpeakerListShown.toggle()
                } label: {
                    Label("Speakers", systemImage: "person.2")
                }
                .help("Speakers")
                .accessibilityLabel("Speakers")
                .popover(isPresented: $isSpeakerListShown, arrowEdge: .bottom) {
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
        .safeAreaBar(edge: .top) {
            if showRawMarkdownToggle {
                Toggle(isOn: $showRawMarkdown) {
                    Text("Raw Markdown")
                        .font(.subheadline.weight(.medium))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                // Full width: sized to the toggle, the bar showed as a patch under the toolbar.
                .frame(maxWidth: .infinity)
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
    }

    private var transcript: Transcript {
        viewModel.shownTranscript ?? inputTranscript
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
            otherSpeakers: TranscriptGrouper.displaySpeakers(of: transcript).filter { $0.id != block.speaker.id },
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

    @ToolbarContentBuilder
    static func toolbarActions(
        onCopy: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onFind: @escaping () -> Void
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                onExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }

            Button {
                onFind()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
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
}

extension Notification.Name {
    static let transcriptSearchRequested = Notification.Name("Scriberman.TranscriptSearchRequested")
}
