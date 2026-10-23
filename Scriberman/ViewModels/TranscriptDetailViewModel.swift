import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TranscriptDetailViewModel {
    private let promptStore: AIPromptStore
    private let aiProviderService: AIProviderService
    private let saveContext: @MainActor (ModelContext) throws -> Void

    let session: any TranscribableSession

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
        saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.session = session
        self.aiProviderService = aiProviderService
        self.promptStore = promptStore
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
        prompts = promptStore.loadPrompts().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if let lastUsedPromptID = promptStore.loadLastUsedPromptID(),
           prompts.contains(where: { $0.id == lastUsedPromptID }) {
            selectedPromptID = lastUsedPromptID
        } else if selectedPromptID == nil {
            selectedPromptID = prompts.first?.id
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
    func commitTitle(_ title: String, context: ModelContext) -> TitleCommitResult {
        let result = Self.saveTitle(title, of: session, context: context, saveContext: saveContext)
        if result == .saved, let recording = session as? RecordingSession {
            rewriteTranscriptMarkdown(for: recording)
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
