import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class TranscriptDetailViewModel {
    private let promptStore: AIPromptStore
    private let aiProviderService: AIProviderService
    private let store: SpeakerEmbeddingStore?
    private let markdownRenderer = MarkdownRenderer()
    private let saveContext: @MainActor (ModelContext) throws -> Void

    let session: any TranscribableSession

    /// The transcript the blocks are made from: the session's displayed transcript as of the last
    /// refresh, and the result of every speaker edit made here.
    ///
    /// Starts as the `transcript` passed to `init`, not read from the session: SwiftUI creates the
    /// model again on every update of the view that owns it, and reading the session decodes the
    /// whole transcript.
    private(set) var shownTranscript: Transcript? {
        didSet { blocks = shownTranscript.map(TranscriptGrouper.makeBlocks(from:)) ?? [] }
    }
    private(set) var blocks: [TranscriptBlock]

    let searchState = TranscriptSearchState()
    var isSearchVisible = false

    /// Stored profiles, for the rename field's suggestions and the speaker list.
    private(set) var profiles: [SpeakerProfileSnapshot] = []

    var prompts: [AIPrompt] = []
    var selectedPromptID: UUID?
    var selectedTransformationID: UUID?
    var transformationErrorMessage: String?

    /// Sessions with a transformation in flight. A second run for one of them is rejected.
    private(set) var runningTransformationSessionIDs: Set<UUID> = []

    var isRunningTransformation: Bool {
        runningTransformationSessionIDs.isEmpty == false
    }

    init(
        session: any TranscribableSession,
        aiProviderService: AIProviderService,
        promptStore: AIPromptStore = AIPromptStore(),
        store: SpeakerEmbeddingStore? = nil,
        transcript: Transcript? = nil,
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.session = session
        self.aiProviderService = aiProviderService
        self.promptStore = promptStore
        self.store = store
        self.shownTranscript = transcript
        self.blocks = transcript.map(TranscriptGrouper.makeBlocks(from:)) ?? []
        self.saveContext = saveContext
    }

    var displayedTranscript: Transcript? {
        session.displayedTranscript
    }

    var finalTranscriptText: String {
        displayedTranscript?.fullText ?? ""
    }

    var originalTranscriptText: String {
        session.transcript?.fullText ?? ""
    }

    var applicationName: String? {
        if let recordingSession = session as? RecordingSession {
            return recordingSession.capturedAppName
        }
        return nil
    }

    // MARK: - Header facts (design D2)

    var durationText: String {
        TimeFormatter.displayFormat(seconds: Float(session.duration))
    }

    var sourcesText: String {
        if session is ImportedSession {
            return "Imported"
        }
        if let applicationName {
            return "Mic + \(applicationName)"
        }
        return "Mic"
    }

    var wordCount: Int {
        finalTranscriptText
            .split(whereSeparator: \.isWhitespace)
            .count
    }

    var availableTransformations: [AITransformation] {
        session.aiTransformations.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var isReprocessed: Bool {
        session.retranscript != nil
    }

    var canReprocess: Bool {
        guard session.mixdownURL != nil else { return false }
        switch session.status {
        case .recording, .converting, .transcribing, .retranscribing:
            return false
        case .recorded, .done, .error:
            return true
        }
    }

    var isReprocessing: Bool {
        session.status == .retranscribing
    }

    var selectedPrompt: AIPrompt? {
        guard let selectedPromptID else { return nil }
        return prompts.first { $0.id == selectedPromptID }
    }

    var selectedTransformation: AITransformation? {
        if let selectedTransformationID,
           let selected = availableTransformations.first(where: { $0.id == selectedTransformationID }) {
            return selected
        }
        return availableTransformations.last
    }

    var runButtonTitle: String {
        availableTransformations.isEmpty ? "Run" : "Rerun"
    }

    var shouldWarnAboutTranscriptLength: Bool {
        aiProviderService.shouldWarnAboutTranscriptLength(finalTranscriptText)
    }

    var isAIEnabled: Bool {
        aiProviderService.isEnabled
    }

    var canRunTransformation: Bool {
        aiProviderService.isEnabled &&
        prompts.isEmpty == false &&
        selectedPrompt != nil &&
        isRunningTransformation == false &&
        finalTranscriptText.isEmpty == false
    }

    func loadPrompts() {
        prompts = Self.sortedPrompts(promptStore.loadPrompts())

        if let lastUsedPromptID = promptStore.loadLastUsedPromptID(),
           prompts.contains(where: { $0.id == lastUsedPromptID }) {
            selectedPromptID = lastUsedPromptID
        } else if selectedPromptID == nil {
            selectedPromptID = prompts.first?.id
        }
    }

    /// Prompts in the order the Transform menus list them.
    static func sortedPrompts(_ prompts: [AIPrompt]) -> [AIPrompt] {
        prompts.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func refreshSelectedTransformation() {
        if availableTransformations.isEmpty {
            selectedTransformationID = nil
            return
        }

        if let selectedTransformationID,
           availableTransformations.contains(where: { $0.id == selectedTransformationID }) {
            return
        }

        selectedTransformationID = availableTransformations.last?.id
    }

    func runTransformation() async {
        guard let selectedPrompt else {
            return
        }

        let request = AITransformationRequest(
            transcript: finalTranscriptText,
            systemPrompt: selectedPrompt.content,
            promptName: selectedPrompt.name,
            modelID: aiProviderService.selectedModelID ?? ""
        )
        await runTransformation(request, session: session, promptID: selectedPrompt.id)
    }

    func runTransformation(
        _ request: AITransformationRequest,
        session: any TranscribableSession,
        promptID: UUID?
    ) async {
        let sessionID = session.id
        guard runningTransformationSessionIDs.contains(sessionID) == false else {
            return
        }

        transformationErrorMessage = nil
        runningTransformationSessionIDs.insert(sessionID)
        defer { runningTransformationSessionIDs.remove(sessionID) }

        do {
            let result = try await aiProviderService.performTransformation(request)

            let transformation = AITransformation(
                promptName: result.promptName,
                modelID: result.modelID,
                resultText: result.text
            )

            var history = session.aiTransformations
            history.append(transformation)
            session.aiTransformations = history
            selectedTransformationID = transformation.id
            promptStore.setLastUsedPromptID(promptID)
        } catch {
            transformationErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Transcript

    /// Picks up a change to the session's displayed transcript made elsewhere: a retranscription or
    /// a restore. After a speaker edit made here this is a no-op, the session already holds it.
    func refreshTranscript() {
        shownTranscript = session.displayedTranscript
        searchState.update(blocks: blocks)
    }

    func activeBlock(at currentTime: Double) -> TranscriptBlock? {
        Self.activeBlock(for: blocks, currentTime: currentTime)
    }

    static func activeBlock(for blocks: [TranscriptBlock], currentTime: Double) -> TranscriptBlock? {
        let time = Float(currentTime)
        return blocks.first { time >= $0.startTime && time < $0.endTime }
    }

    static func seekAndPlay(block: TranscriptBlock, player: any TranscriptPlaybackControlling) {
        player.seek(to: Double(block.startTime))
        player.play()
    }

    var rawMarkdown: String {
        guard let shownTranscript else { return "" }
        return markdownRenderer.renderMarkdown(session: session, transcript: shownTranscript)
    }

    // MARK: - Find

    func updateSearch() {
        searchState.update(blocks: blocks)
    }

    func presentSearch() {
        isSearchVisible = true
    }

    /// Empties the query and removes its highlights. Hiding the find bar is the caller's, so it can
    /// animate it.
    func clearSearch() {
        searchState.query = ""
        searchState.update(blocks: blocks)
    }

    /// Opens the find bar on the seeded query with the seeded match selected. Returns `false`, and
    /// changes nothing, for no seed or an empty query.
    ///
    /// No playback is started: locating text and listening to it are separate intentions.
    @discardableResult
    func applySearchSeed(_ searchSeed: TranscriptStudySearchSeed?) -> Bool {
        guard let searchSeed, !searchSeed.query.isEmpty else { return false }

        searchState.query = searchSeed.query
        searchState.update(blocks: blocks)
        if let blockID = searchSeed.blockID {
            searchState.selectFirstMatch(inBlock: blockID)
        }
        isSearchVisible = true
        return true
    }

    // MARK: - Speaker edits

    /// Loads stored profiles for the rename field's suggestions.
    func loadProfiles() {
        guard let store else { return }
        Task {
            do {
                profiles = try await store.fetchAllSnapshots()
            } catch {
                Self.logger.error("Loading speaker profiles for suggestions failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The latest speaker memory update: an edit's, or an undo's or redo's. Each one waits for the
    /// one before it, so undo never restores memory under an update still running.
    @ObservationIgnored private(set) var speakerMemoryUpdate: Task<Void, Never>?

    /// Renames speaker `id` and teaches speaker memory the name. The returned task is the speaker
    /// memory update, `nil` when there is none.
    @discardableResult
    func renameSpeaker(id: String, to newName: String, undoManager: UndoManager? = nil) -> Task<Void, Never>? {
        guard let shownTranscript else { return nil }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousLabel = shownTranscript.speakers.first { $0.id == id }?.label
        guard !name.isEmpty, name != previousLabel,
              let updatedTranscript = Self.renameSpeaker(id: id, to: name, in: shownTranscript, of: session)
        else { return nil }
        self.shownTranscript = updatedTranscript

        // Renaming to the label it already has teaches nothing new.
        guard let store, previousLabel?.lowercased() != name.lowercased() else {
            registerSpeakerEditUndo(UndoActionName.renameSpeaker, restoring: SpeakerEditState(transcript: shownTranscript), over: updatedTranscript, undoManager: undoManager)
            return nil
        }
        let source = Self.voiceprintSource(for: id, of: session)
        let before = SpeakerEditState(transcript: shownTranscript, sources: [source])
        registerSpeakerEditUndo(UndoActionName.renameSpeaker, restoring: before, over: updatedTranscript, undoManager: undoManager)
        return enqueueSpeakerMemoryUpdate(failure: "Teaching speaker memory a rename failed") {
            before.memory = try await store.snapshot(of: before.sources)
            try await Self.updateSpeakerMemory(forRenaming: id, to: name, in: updatedTranscript, source: source, store: store)
        }
    }

    /// Gives one block to speaker `speakerID`, or to a new speaker for `nil`. Speaker memory does
    /// not change.
    func assign(_ block: TranscriptBlock, to speakerID: String?, undoManager: UndoManager? = nil) {
        guard let shownTranscript,
              let updatedTranscript = Self.assign(segmentIDs: Set(block.segmentIDs), to: speakerID, in: shownTranscript, of: session)
        else { return }
        self.shownTranscript = updatedTranscript
        registerSpeakerEditUndo(UndoActionName.reassignSpeaker, restoring: SpeakerEditState(transcript: shownTranscript), over: updatedTranscript, undoManager: undoManager)
    }

    /// Merges speaker `id` into `targetID`, then teaches speaker memory as a rename of `id` to the
    /// target's label would, when the target is named. The returned task is the speaker memory
    /// update, `nil` when there is none.
    @discardableResult
    func mergeSpeaker(_ id: String, into targetID: String, undoManager: UndoManager? = nil) -> Task<Void, Never>? {
        guard let original = shownTranscript,
              let updatedTranscript = Self.mergeSpeaker(id, into: targetID, in: original, of: session)
        else { return nil }
        shownTranscript = updatedTranscript
        guard let store else {
            registerSpeakerEditUndo(UndoActionName.mergeSpeaker, restoring: SpeakerEditState(transcript: original), over: updatedTranscript, undoManager: undoManager)
            return nil
        }
        let source = Self.voiceprintSource(for: id, of: session)
        let targetSource = Self.voiceprintSource(for: targetID, of: session)
        let before = SpeakerEditState(transcript: original, sources: [source, targetSource])
        registerSpeakerEditUndo(UndoActionName.mergeSpeaker, restoring: before, over: updatedTranscript, undoManager: undoManager)
        return enqueueSpeakerMemoryUpdate(failure: "Teaching speaker memory a merge failed") {
            before.memory = try await store.snapshot(of: before.sources)
            try await Self.updateSpeakerMemory(
                forMerging: id, into: targetID, in: original, source: source, targetSource: targetSource, store: store
            )
        }
    }

    /// Resets speaker `id` to `Speaker N` and removes the voiceprints it taught. The returned task
    /// is the speaker memory update, `nil` when there is none.
    @discardableResult
    func resetSpeaker(_ id: String, undoManager: UndoManager? = nil) -> Task<Void, Never>? {
        guard let shownTranscript,
              let updatedTranscript = Self.resetSpeaker(id, in: shownTranscript, of: session)
        else { return nil }
        self.shownTranscript = updatedTranscript
        guard let store else {
            registerSpeakerEditUndo(UndoActionName.resetSpeaker, restoring: SpeakerEditState(transcript: shownTranscript), over: updatedTranscript, undoManager: undoManager)
            return nil
        }
        let source = Self.voiceprintSource(for: id, of: session)
        let before = SpeakerEditState(transcript: shownTranscript, sources: [source])
        registerSpeakerEditUndo(UndoActionName.resetSpeaker, restoring: before, over: updatedTranscript, undoManager: undoManager)
        return enqueueSpeakerMemoryUpdate(failure: "Removing a reset speaker from speaker memory failed") {
            before.memory = try await store.snapshot(of: before.sources)
            try await store.forget(source: source)
        }
    }

    // MARK: - Undo

    /// One side of a speaker edit, for undo and redo: the displayed transcript and what speaker
    /// memory held for the edit's voiceprint sources. `memory` is filled in by the memory update
    /// queue, before the update it precedes runs.
    @MainActor
    private final class SpeakerEditState {
        let transcript: Transcript
        let sources: Set<VoiceprintSource>
        var memory: SpeakerMemorySnapshot?

        init(transcript: Transcript, sources: Set<VoiceprintSource> = []) {
            self.transcript = transcript
            self.sources = sources
        }
    }

    /// Registers putting the session back to `state`, from `current`, with `undoManager`. Undoing
    /// registers the opposite, which is the redo.
    private func registerSpeakerEditUndo(
        _ actionName: String,
        restoring state: SpeakerEditState,
        over current: Transcript,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        let wasStored = Self.isStored(session)
        // The handler holds the view model: the undo manager does not retain its target, and the
        // view that made the edit may be gone by the time it is undone.
        undoManager.registerUndo(withTarget: self) { [weak undoManager] _ in
            self.restoreSpeakerEdit(actionName, to: state, from: current, wasStored: wasStored, undoManager: undoManager)
        }
        undoManager.setActionName(actionName)
    }

    private func restoreSpeakerEdit(
        _ actionName: String,
        to state: SpeakerEditState,
        from current: Transcript,
        wasStored: Bool,
        undoManager: UndoManager?
    ) {
        // A deleted session, or a transcript changed since by a retranscription or a restore, is
        // left as it is.
        guard !(wasStored && !Self.isStored(session)), session.displayedTranscript == current else {
            Self.logger.notice("Skipped undoing a speaker edit: the transcript changed since.")
            return
        }
        let currentState = SpeakerEditState(transcript: current, sources: state.sources)
        Self.writeDisplayed(state.transcript, to: session)
        shownTranscript = state.transcript
        registerSpeakerEditUndo(actionName, restoring: currentState, over: state.transcript, undoManager: undoManager)

        guard let store, !state.sources.isEmpty else { return }
        enqueueSpeakerMemoryUpdate(failure: "Restoring speaker memory for an undone speaker edit failed") {
            currentState.memory = try await store.snapshot(of: state.sources)
            if let memory = state.memory {
                try await store.restore(memory)
            }
        }
    }

    /// Runs `operation` after every speaker memory update queued before it, then reloads the
    /// profiles.
    @discardableResult
    private func enqueueSpeakerMemoryUpdate(
        failure: String,
        _ operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Never> {
        let previous = speakerMemoryUpdate
        let task = Task {
            await previous?.value
            do {
                try await operation()
                loadProfiles()
            } catch {
                Self.logger.error("\(failure, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        speakerMemoryUpdate = task
        return task
    }

    /// Whether `session` is in a store. A session that was and is no longer has been deleted, and
    /// an undo must not touch it.
    private static func isStored(_ session: any TranscribableSession) -> Bool {
        guard let model = session as? any PersistentModel else { return false }
        return model.modelContext != nil && !model.isDeleted
    }

    private static let logger = Logger(subsystem: "Scriberman", category: "TranscriptDetailViewModel")
}

// MARK: - Speaker edits on a session

extension TranscriptDetailViewModel {
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

    // MARK: - Title

    /// What a title commit did, for the view to report.
    enum TitleCommitResult: Equatable {
        case saved
        /// Saving the store failed. The session keeps its previous title.
        case saveFailed(String)
    }

    /// Saves `title` as the session's title, then rewrites `transcript.md`, which carries it.
    ///
    /// A failed save is rolled back and the file is left alone, so the store, the list and the file
    /// all keep the previous title.
    @discardableResult
    func commitTitle(_ title: String, context: ModelContext, undoManager: UndoManager? = nil) -> TitleCommitResult {
        let previousTitle = session.title
        let result = Self.saveTitle(title, of: session, context: context, saveContext: saveContext)
        if result == .saved, let recording = session as? RecordingSession {
            rewriteTranscriptMarkdown(for: recording)
        }
        if result == .saved, title != previousTitle, let undoManager {
            let wasStored = Self.isStored(session)
            // The handler holds the view model, as for speaker edits.
            undoManager.registerUndo(withTarget: self) { [weak undoManager] _ in
                guard !(wasStored && !Self.isStored(self.session)) else { return }
                if case .saveFailed(let message) = self.commitTitle(previousTitle, context: context, undoManager: undoManager) {
                    Self.logger.error("Saving an undone title failed: \(message, privacy: .public)")
                }
            }
            undoManager.setActionName(UndoActionName.renameSession)
        }
        return result
    }

    /// Sets and saves the title without touching `transcript.md`, rolling back a failed save. The
    /// recording view uses this directly: its file is rewritten when the recording stops.
    static func saveTitle(
        _ title: String,
        of session: any TranscribableSession,
        context: ModelContext,
        saveContext: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) -> TitleCommitResult {
        session.title = title
        do {
            try saveContext(context)
            return .saved
        } catch {
            context.rollback()
            return .saveFailed(error.localizedDescription)
        }
    }
}

// MARK: - Undo action names

/// The names Edit > Undo and Redo show for each undoable edit.
enum UndoActionName {
    static let renameSession = "Rename"
    static let changeTags = "Change Tags"
    static let renameSpeaker = "Speaker Name"
    static let mergeSpeaker = "Speaker Merge"
    static let reassignSpeaker = "Passage Speaker"
    static let resetSpeaker = "Speaker Reset"
}
