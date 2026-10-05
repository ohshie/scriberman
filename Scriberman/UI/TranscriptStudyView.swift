import OSLog
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
    /// The block whose speaker is being renamed inline.
    @State private var renamingBlockID: UUID?
    /// Stored profiles, loaded when a rename starts, for the rename field's suggestions.
    @State private var profiles: [SpeakerProfileSnapshot] = []
    @State private var isSpeakerListShown = false

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
                                    if renamingBlockID != block.id {
                                        renamingBlockID = nil
                                    }
                                    Self.seekAndPlay(block: block, player: audioPlayerViewModel)
                                },
                                speakerEditing: speakerEditing(for: block)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    loadProfiles()
                    isSpeakerListShown.toggle()
                } label: {
                    Label("Speakers", systemImage: "person.2")
                }
                .help("Speakers")
                .accessibilityLabel("Speakers")
                .popover(isPresented: $isSpeakerListShown, arrowEdge: .bottom) {
                    SessionSpeakerListView(
                        transcript: transcript,
                        profiles: profiles,
                        onRename: { id, name in renameSpeaker(id: id, to: name) },
                        onMerge: { id, targetID in mergeSpeaker(id, into: targetID) },
                        onReset: { id in resetSpeaker(id) }
                    )
                }
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
                // Full width: sized to the toggle, the bar showed as a patch under the toolbar.
                .frame(maxWidth: .infinity)
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

    private func speakerEditing(for block: TranscriptBlock) -> TranscriptBlockView.SpeakerEditing {
        TranscriptBlockView.SpeakerEditing(
            isRenaming: renamingBlockID == block.id,
            profiles: profiles,
            otherSpeakers: TranscriptGrouper.displaySpeakers(of: transcript).filter { $0.id != block.speaker.id },
            onBeginRename: {
                renamingBlockID = block.id
                loadProfiles()
            },
            onEndRename: {
                if renamingBlockID == block.id {
                    renamingBlockID = nil
                }
            },
            onRename: { name in
                renameSpeaker(id: block.speaker.id, to: name)
            },
            onAssign: { speakerID in
                assign(block, to: speakerID)
            }
        )
    }

    /// Loads stored profiles for the rename field's suggestions.
    private func loadProfiles() {
        guard let store else { return }
        Task {
            do {
                profiles = try await store.fetchAllSnapshots()
            } catch {
                Self.logger.error("Loading speaker profiles for suggestions failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Gives one block to speaker `speakerID`, or to a new speaker for `nil`. Speaker memory does
    /// not change.
    private func assign(_ block: TranscriptBlock, to speakerID: String?) {
        guard let updatedTranscript = Self.assign(segmentIDs: Set(block.segmentIDs), to: speakerID, in: transcript, of: session) else { return }
        transcript = updatedTranscript
    }

    /// Gives the segments `segmentIDs` to speaker `speakerID`, or to a new speaker for `nil`, and
    /// writes the result to `session`'s displayed pass. `nil` when the speaker is not in the
    /// transcript.
    static func assign(
        segmentIDs: Set<UUID>,
        to speakerID: String?,
        in transcript: Transcript,
        of session: any TranscribableSession
    ) -> Transcript? {
        var base = transcript
        let targetID: String
        if let speakerID {
            guard transcript.speakers.contains(where: { $0.id == speakerID }) else { return nil }
            targetID = speakerID
        } else {
            (base, targetID) = TranscriptSpeakerEditing.addSpeaker(to: transcript)
        }
        let updatedTranscript = TranscriptSpeakerEditing.reassign(segmentIDs: segmentIDs, to: targetID, in: base)
        writeDisplayed(updatedTranscript, to: session)
        return updatedTranscript
    }

    /// Merges speaker `id` into `targetID`, then teaches speaker memory as a rename of `id` to the
    /// target's label would, when the target is named.
    private func mergeSpeaker(_ id: String, into targetID: String) {
        let original = transcript
        guard let updatedTranscript = Self.mergeSpeaker(id, into: targetID, in: original, of: session) else { return }
        transcript = updatedTranscript
        guard let store else { return }
        let source = Self.voiceprintSource(for: id, of: session)
        let targetSource = Self.voiceprintSource(for: targetID, of: session)
        Task {
            do {
                try await Self.updateSpeakerMemory(
                    forMerging: id, into: targetID, in: original, source: source, targetSource: targetSource, store: store
                )
                loadProfiles()
            } catch {
                Self.logger.error("Teaching speaker memory a merge failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Resets speaker `id` to `Speaker N` and removes the voiceprints it taught.
    private func resetSpeaker(_ id: String) {
        guard let updatedTranscript = Self.resetSpeaker(id, in: transcript, of: session) else { return }
        transcript = updatedTranscript
        guard let store else { return }
        let source = Self.voiceprintSource(for: id, of: session)
        Task {
            do {
                try await store.forget(source: source)
                loadProfiles()
            } catch {
                Self.logger.error("Removing a reset speaker from speaker memory failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Merges speaker `id` into `targetID` in `transcript` and writes the result to `session`'s
    /// displayed pass. `nil` when either speaker is missing.
    static func mergeSpeaker(
        _ id: String,
        into targetID: String,
        in transcript: Transcript,
        of session: any TranscribableSession
    ) -> Transcript? {
        guard let updatedTranscript = TranscriptSpeakerEditing.merge(id, into: targetID, in: transcript) else { return nil }
        writeDisplayed(updatedTranscript, to: session)
        return updatedTranscript
    }

    /// Resets speaker `id` in `transcript` and writes the result to `session`'s displayed pass.
    /// `nil` when the speaker is missing.
    static func resetSpeaker(_ id: String, in transcript: Transcript, of session: any TranscribableSession) -> Transcript? {
        guard let updatedTranscript = TranscriptSpeakerEditing.reset(id, in: transcript) else { return nil }
        writeDisplayed(updatedTranscript, to: session)
        return updatedTranscript
    }

    /// Records in speaker memory that speaker `id` of `transcript`, the transcript before the
    /// merge, was merged into `targetID`: what `id` taught is removed, and when the target is named
    /// its profile is taught `id`'s voiceprints under the target's source.
    static func updateSpeakerMemory(
        forMerging id: String,
        into targetID: String,
        in transcript: Transcript,
        source: VoiceprintSource,
        targetSource: VoiceprintSource,
        store: SpeakerEmbeddingStore
    ) async throws {
        let voiceprints = teachableVoiceprints(of: id, in: transcript) ?? []
        let targetLabel = transcript.speakers.first { $0.id == targetID }?.label
        let name = targetLabel.flatMap { TranscriptSpeakerEditing.isUnnamed(label: $0) ? nil : $0 }
        try await store.retarget(from: source, to: targetSource, name: name, voiceprints: voiceprints)
    }

    private func renameSpeaker(id: String, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousLabel = transcript.speakers.first { $0.id == id }?.label
        guard !name.isEmpty, name != previousLabel,
              let updatedTranscript = Self.renameSpeaker(id: id, to: name, in: transcript, of: session)
        else { return }
        self.transcript = updatedTranscript

        // Renaming to the label it already has teaches nothing new.
        guard let store, previousLabel?.lowercased() != name.lowercased() else { return }
        let source = Self.voiceprintSource(for: id, of: session)
        Task {
            do {
                try await Self.updateSpeakerMemory(forRenaming: id, to: name, in: updatedTranscript, source: source, store: store)
                loadProfiles()
            } catch {
                Self.logger.error("Teaching speaker memory a rename failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static let logger = Logger(subsystem: "Scriberman", category: "TranscriptStudyView")

    /// The pass a speaker edit is written to, decided as `writeDisplayed` decides it.
    static func displayedPass(of session: any TranscribableSession) -> TranscriptPass {
        session.retranscript != nil ? .retranscript : .transcript
    }

    /// The source of the voiceprints speaker `id` of `session`'s displayed pass teaches.
    static func voiceprintSource(for id: String, of session: any TranscribableSession) -> VoiceprintSource {
        VoiceprintSource(sessionID: session.id, pass: displayedPass(of: session), speakerID: id)
    }

    /// Speaker `id`'s voiceprints when they can reach speaker memory: present, and in the current
    /// voiceprint space.
    static func teachableVoiceprints(of id: String, in transcript: Transcript) -> [[Float]]? {
        guard transcript.voiceprintSpace == VoiceprintSpace.current,
              let voiceprints = transcript.speakerVoiceprints?[id]?.filter({ !$0.isEmpty }),
              !voiceprints.isEmpty
        else { return nil }
        return voiceprints
    }

    /// Teaches speaker memory that speaker `id` is called `name`: the voiceprints taught earlier
    /// from `source` move to the profile with that name, which is created when absent, with the
    /// speaker's voiceprints in `transcript`. Nothing changes when the transcript has no voiceprint
    /// for the speaker or its voiceprints are from another voiceprint space.
    static func updateSpeakerMemory(
        forRenaming id: String,
        to name: String,
        in transcript: Transcript,
        source: VoiceprintSource,
        store: SpeakerEmbeddingStore
    ) async throws {
        guard let voiceprints = teachableVoiceprints(of: id, in: transcript) else { return }
        try await store.teach(name: name, source: source, voiceprints: voiceprints)
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
        guard let updatedTranscript = TranscriptSpeakerEditing.rename(id, to: newName, in: transcript) else { return nil }
        writeDisplayed(updatedTranscript, to: session)
        return updatedTranscript
    }

    private static func writeDisplayed(_ transcript: Transcript, to session: any TranscribableSession) {
        if session.retranscript != nil {
            session.retranscript = transcript
        } else {
            session.transcript = transcript
        }
        if let recording = session as? RecordingSession {
            rewriteTranscriptMarkdown(for: recording)
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
