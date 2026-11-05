import Foundation
import Observation
import OSLog
import SwiftData

/// Runs a saved prompt on a session. One instance serves every window and the extension API, so
/// it holds the one set of sessions with a run under way.
///
/// Each run is an operation with an id and a state, kept in memory until the app quits, so a
/// caller that started a run can read how it ended.
@MainActor
@Observable
final class AITransformationRunner {
    enum OperationState: Equatable, Sendable {
        case running
        case succeeded(transformationID: UUID)
        case failed(Failure)
    }

    struct Failure: Equatable, Sendable {
        enum Code: Equatable, Sendable {
            /// AI is off, or has no API key or no model.
            case aiNotConfigured
            case noTranscript
            /// The provider answered with an error.
            case providerFailed
            /// The session was deleted while the run was under way; nothing was written.
            case notFound
            /// The result could not be saved to the store.
            case saveFailed
        }

        let code: Code
        /// The error's own description; nil when there is no error to describe.
        let message: String?
    }

    enum StartRefusal: Error, Equatable {
        /// The session already has a run under way.
        case alreadyRunning
    }

    private let aiProviderService: any AIProviderServiceProtocol
    private let promptStore: AIPromptStore
    /// The sessions' background jobs: a delete cancels a run and waits for it.
    private let sessionJobs: SessionJobs

    private var runningSessionIDs: Set<UUID> = []
    private var operations: [UUID: OperationState] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<OperationState, Never>] = [:]

    init(
        aiProviderService: any AIProviderServiceProtocol,
        promptStore: AIPromptStore,
        sessionJobs: SessionJobs
    ) {
        self.aiProviderService = aiProviderService
        self.promptStore = promptStore
        self.sessionJobs = sessionJobs
    }

    func isRunning(_ sessionID: UUID) -> Bool {
        runningSessionIDs.contains(sessionID)
    }

    /// Starts a run of `prompt` on `session` and returns its operation id. The request uses the
    /// session's displayed transcript and the model selected now. A session that already has a
    /// run under way is refused.
    func start(prompt: AIPrompt, on session: any TranscribableSession) throws(StartRefusal) -> UUID {
        let sessionID = session.id
        guard !runningSessionIDs.contains(sessionID) else {
            throw .alreadyRunning
        }

        let operationID = UUID()
        let request = AITransformationRequest(
            transcript: session.displayedTranscript?.fullText ?? "",
            systemPrompt: prompt.content,
            promptName: prompt.name,
            modelID: aiProviderService.selectedModelID ?? ""
        )
        // An unmet requirement fails the operation at once, so a caller can read the failure
        // right after `start` returns.
        if let unmet = unmetRequirement(of: request) {
            operations[operationID] = .failed(Self.failure(for: unmet))
            return operationID
        }
        let generation = sessionJobs.generation(of: sessionID)
        runningSessionIDs.insert(sessionID)
        operations[operationID] = .running
        tasks[operationID] = Task {
            let state = await run(request, on: session, promptID: prompt.id, generation: generation)
            operations[operationID] = state
            tasks[operationID] = nil
            runningSessionIDs.remove(sessionID)
            return state
        }
        return operationID
    }

    /// The operation's state once it has ended; nil for an id this runner never gave.
    func completion(of operationID: UUID) async -> OperationState? {
        if let task = tasks[operationID] {
            return await task.value
        }
        return operations[operationID]
    }

    func state(of operationID: UUID) -> OperationState? {
        operations[operationID]
    }

    // MARK: - Running

    private func run(
        _ request: AITransformationRequest,
        on session: any TranscribableSession,
        promptID: UUID,
        generation: SessionJobs.Generation
    ) async -> OperationState {
        // The request runs in a task of its own, so a delete of the session cancels it and waits
        // for it.
        let aiProviderService = aiProviderService
        let outcome = await sessionJobs.run(session.id) { _ in
            do {
                return Result<AITransformationResult, any Error>.success(
                    try await aiProviderService.performTransformation(request)
                )
            } catch {
                return .failure(error)
            }
        }
        guard sessionJobs.mayWrite(generation), !Self.isDeleted(session) else {
            Self.logger.notice("Transformation for session \(session.id, privacy: .public) not saved: the session was deleted.")
            return .failed(Failure(code: .notFound, message: nil))
        }

        let result: AITransformationResult
        switch outcome {
        case .success(let value):
            result = value
        case .failure(let error):
            return .failed(Self.failure(for: error))
        }

        let transformation = AITransformation(
            promptName: result.promptName,
            modelID: result.modelID,
            resultText: result.text
        )
        var history = session.aiTransformations
        history.append(transformation)
        session.aiTransformations = history
        do {
            try (session as? any PersistentModel)?.modelContext?.save()
        } catch {
            Self.logger.error("Transformation for session \(session.id, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
            return .failed(Failure(code: .saveFailed, message: error.localizedDescription))
        }
        promptStore.setLastUsedPromptID(promptID)
        return .succeeded(transformationID: transformation.id)
    }

    /// What has to be in place before the provider is asked, in the order the provider checks it.
    private func unmetRequirement(of request: AITransformationRequest) -> AIProviderService.AITransformationError? {
        if !aiProviderService.isEnabled {
            return .disabled
        }
        if request.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyTranscript
        }
        if !aiProviderService.isConfigured {
            return .noAPIKeyConfigured
        }
        if request.modelID.isEmpty {
            return .noModelSelected
        }
        return nil
    }

    private static func failure(for error: any Error) -> Failure {
        let code: Failure.Code
        switch error as? AIProviderService.AITransformationError {
        case .disabled, .noAPIKeyConfigured, .noModelSelected:
            code = .aiNotConfigured
        case .emptyTranscript:
            code = .noTranscript
        default:
            code = .providerFailed
        }
        return Failure(code: code, message: error.localizedDescription)
    }

    private static func isDeleted(_ session: any TranscribableSession) -> Bool {
        (session as? any PersistentModel)?.isDeleted ?? false
    }

    private static let logger = Logger(subsystem: "Scriberman", category: "AITransformationRunner")
}
