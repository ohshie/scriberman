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
        onExport: @escaping () -> Void
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
        }
    }
}
