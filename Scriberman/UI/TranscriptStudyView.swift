import SwiftUI

@MainActor
protocol TranscriptPlaybackControlling: AnyObject {
    func seek(to seconds: Double)
    func play()
}

extension AudioPlayerViewModel: TranscriptPlaybackControlling {}

struct TranscriptStudyView: View {
    let session: any TranscribableSession
    let audioPlayerViewModel: AudioPlayerViewModel
    @Binding var autoScrollEnabled: Bool
    @State private var transcript: Transcript
    let store: SpeakerEmbeddingStore?
    let showRawMarkdownToggle: Bool

    @State private var showRawMarkdown = false
    @State private var isSearchVisible = false
    @State private var searchState = TranscriptSearchState()
    @State private var scrollTargetID: UUID?

    private let markdownRenderer = MarkdownRenderer()

    init(
        session: any TranscribableSession,
        audioPlayerViewModel: AudioPlayerViewModel,
        autoScrollEnabled: Binding<Bool>,
        transcript: Transcript,
        store: SpeakerEmbeddingStore? = nil,
        showRawMarkdownToggle: Bool = true
    ) {
        self.session = session
        self.audioPlayerViewModel = audioPlayerViewModel
        self._autoScrollEnabled = autoScrollEnabled
        self._transcript = State(initialValue: transcript)
        self.store = store
        self.showRawMarkdownToggle = showRawMarkdownToggle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showRawMarkdown {
                    Text(rawMarkdown)
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
                                    Self.seekAndPlay(block: block, player: audioPlayerViewModel)
                                },
                                onSpeakerRename: { newName in
                                    renameSpeaker(id: block.speaker.id, to: newName)
                                }
                            )
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
        .onChange(of: searchState.query) {
            searchState.update(blocks: blocks)
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
        .safeAreaInset(edge: .top) {
            if showRawMarkdownToggle {
                Toggle(isOn: $showRawMarkdown) {
                    Text("Raw Markdown")
                        .font(.subheadline.weight(.medium))
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom) {
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
        .overlay {
            Button("Find") {
                presentSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0.001)
            .accessibilityHidden(true)
        }
    }

    private var blocks: [TranscriptBlock] {
        TranscriptGrouper.makeBlocks(from: transcript)
    }

    private var activeBlock: TranscriptBlock? {
        Self.activeBlock(for: blocks, currentTime: audioPlayerViewModel.currentTime)
    }

    static func activeBlock(for blocks: [TranscriptBlock], currentTime: Double) -> TranscriptBlock? {
        let time = Float(currentTime)
        return blocks.first { time >= $0.startTime && time < $0.endTime }
    }

    @MainActor
    static func seekAndPlay(block: TranscriptBlock, player: any TranscriptPlaybackControlling) {
        player.seek(to: Double(block.startTime))
        player.play()
    }

    private var rawMarkdown: String {
        markdownRenderer.renderMarkdown(session: session, transcript: transcript)
    }

    private func renameSpeaker(id: String, to newName: String) {
        var updatedTranscript = transcript
        var updatedSpeakers = updatedTranscript.speakers
        if let index = updatedSpeakers.firstIndex(where: { $0.id == id }) {
            let oldSpeaker = updatedSpeakers[index]
            updatedSpeakers[index] = TranscriptSpeaker(id: oldSpeaker.id, label: newName, colorHex: oldSpeaker.colorHex)
            updatedTranscript = Transcript(
                fullText: updatedTranscript.fullText,
                segments: updatedTranscript.segments,
                speakers: updatedSpeakers,
                speakerEmbeddings: updatedTranscript.speakerEmbeddings
            )
            self.transcript = updatedTranscript
            
            // Persist back to session
            if session.retranscript != nil {
                session.retranscript = updatedTranscript
            } else {
                session.transcript = updatedTranscript
            }

            // Enroll in profile database if we have an embedding
            if let embedding = updatedTranscript.speakerEmbeddings?[id], let store = store {
                Task {
                    try? await store.enrollSpeaker(name: newName, embedding: embedding)
                }
            }
        }
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

    private func presentSearch() {
        withAnimation {
            isSearchVisible = true
        }
    }

    private func dismissSearch() {
        searchState.query = ""
        searchState.update(blocks: blocks)
        withAnimation {
            isSearchVisible = false
        }
    }
}

extension Notification.Name {
    static let transcriptSearchRequested = Notification.Name("Scriberman.TranscriptSearchRequested")
}
