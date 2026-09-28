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
    @State private var transcript: Transcript
    /// The transcript the caller passed in, kept to notice when the session's displayed
    /// transcript changes while the view is open (a retranscription or a restore).
    private let inputTranscript: Transcript
    let store: SpeakerEmbeddingStore?
    let showRawMarkdownToggle: Bool
    /// A search to apply on opening, or `nil` to open as the view always has — empty find bar, no
    /// match selected.
    let searchSeed: TranscriptStudySearchSeed?

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
        showRawMarkdownToggle: Bool = true,
        searchSeed: TranscriptStudySearchSeed? = nil
    ) {
        self.session = session
        self.audioPlayerViewModel = audioPlayerViewModel
        self._autoScrollEnabled = autoScrollEnabled
        self._transcript = State(initialValue: transcript)
        self.inputTranscript = transcript
        self.store = store
        self.showRawMarkdownToggle = showRawMarkdownToggle
        self.searchSeed = searchSeed
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
        // Keyed on the seed, so opening the same match again re-applies it: selecting a result
        // whose session is already open changes no binding the view could otherwise notice.
        .task(id: searchSeed) {
            applySearchSeed()
        }
        // A retranscription or restore changes the session's displayed transcript while the view
        // is open. The view's own speaker rename writes the same value back, so this is a no-op then.
        .onChange(of: inputTranscript) {
            transcript = inputTranscript
            searchState.update(blocks: blocks)
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
        guard let updatedTranscript = Self.renameSpeaker(id: id, to: newName, in: transcript, of: session) else {
            return
        }
        self.transcript = updatedTranscript

        guard let store else { return }
        Task {
            let unlinked = (try? await Self.updateSpeakerMemory(
                forRenaming: id,
                to: newName,
                in: updatedTranscript,
                store: store
            )) ?? false
            if unlinked, let transcript = Self.removingProfileLink(for: id, in: self.transcript, of: session) {
                self.transcript = transcript
            }
        }
    }

    /// Teaches speaker memory that speaker `id` is called `name`, using the voiceprint and profile
    /// link stored in `transcript`. Returns `true` when the speaker's profile link must be removed.
    ///
    /// A link means the live session that made this transcript auto-enrolled the profile, so the
    /// transcript owns it: it is renamed, or, when another profile already has the name, merged
    /// into that profile and deleted. Without a live link the voiceprint goes to the profile with
    /// the new name, as for a speaker matched to someone else's existing profile.
    static func updateSpeakerMemory(
        forRenaming id: String,
        to name: String,
        in transcript: Transcript,
        store: SpeakerEmbeddingStore
    ) async throws -> Bool {
        let embedding = transcript.speakerEmbeddings?[id]
        if let linkedID = transcript.speakerProfileIDs?[id],
           let linked = try await store.findProfileSnapshot(byID: linkedID) {
            if let existingID = try await store.profileID(forName: name, excluding: linkedID) {
                try await store.updateEmbedding(profileID: existingID, embedding: embedding ?? linked.embedding)
                try await store.deleteProfile(id: linkedID)
                return true
            }
            try await store.renameProfile(id: linkedID, name: name)
            return false
        }
        if let embedding {
            try await enrollRenamedSpeaker(name: name, embedding: embedding, in: store)
        }
        return false
    }

    /// Gives the renamed speaker's voiceprint to the profile the user named: the existing profile
    /// with that name (case-insensitive) is updated, otherwise a new one is created.
    static func enrollRenamedSpeaker(name: String, embedding: [Float], in store: SpeakerEmbeddingStore) async throws {
        if let profileID = try await store.profileID(forName: name) {
            try await store.updateEmbedding(profileID: profileID, embedding: embedding)
        } else {
            try await store.enrollNamedSpeaker(name: name, embedding: embedding)
        }
    }

    /// Renames a speaker in `transcript` and writes the result to `session`'s displayed pass.
    /// Returns the updated transcript, or `nil` when the speaker is not in it.
    ///
    /// `session` is the only session written: the caller passes the one the view belongs to.
    static func renameSpeaker(
        id: String,
        to newName: String,
        in transcript: Transcript,
        of session: any TranscribableSession
    ) -> Transcript? {
        var updatedSpeakers = transcript.speakers
        guard let index = updatedSpeakers.firstIndex(where: { $0.id == id }) else { return nil }
        let oldSpeaker = updatedSpeakers[index]
        updatedSpeakers[index] = TranscriptSpeaker(id: oldSpeaker.id, label: newName, colorHex: oldSpeaker.colorHex)
        let updatedTranscript = Transcript(
            fullText: transcript.fullText,
            segments: transcript.segments,
            speakers: updatedSpeakers,
            speakerEmbeddings: transcript.speakerEmbeddings,
            speakerProfileIDs: transcript.speakerProfileIDs
        )
        writeDisplayed(updatedTranscript, to: session)
        return updatedTranscript
    }

    /// Drops speaker `id`'s profile link from `transcript` and writes the result to `session`'s
    /// displayed pass. Returns the updated transcript, or `nil` when there is no such link.
    static func removingProfileLink(
        for id: String,
        in transcript: Transcript,
        of session: any TranscribableSession
    ) -> Transcript? {
        guard transcript.speakerProfileIDs?[id] != nil else { return nil }
        var updatedTranscript = transcript
        updatedTranscript.speakerProfileIDs?[id] = nil
        if updatedTranscript.speakerProfileIDs?.isEmpty == true {
            updatedTranscript.speakerProfileIDs = nil
        }
        writeDisplayed(updatedTranscript, to: session)
        return updatedTranscript
    }

    private static func writeDisplayed(_ transcript: Transcript, to session: any TranscribableSession) {
        if session.retranscript != nil {
            session.retranscript = transcript
        } else {
            session.transcript = transcript
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

    /// Opens the find bar on the seeded query with the seeded match selected, and scrolls to it.
    ///
    /// Auto-scroll is turned off for the same reason presenting the find bar does: playback
    /// position must not drag the view away from the match the user came here to read. No playback
    /// is started — locating text and listening to it are separate intentions.
    private func applySearchSeed() {
        guard let searchSeed, !searchSeed.query.isEmpty else { return }

        searchState.query = searchSeed.query
        searchState.update(blocks: blocks)
        if let blockID = searchSeed.blockID {
            searchState.selectFirstMatch(inBlock: blockID)
        }

        autoScrollEnabled = false
        isSearchVisible = true
        scrollTargetID = searchState.currentMatch?.blockID
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
