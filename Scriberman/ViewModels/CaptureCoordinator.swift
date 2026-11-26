import CoreGraphics
import Foundation
import Observation
import OSLog
import SwiftData

/// Everything a start captures, chosen as one value so one caller's choice cannot be changed by
/// another caller's selections.
struct CaptureChoice {
    var title: String
    /// `nil` records from the system default microphone.
    var microphone: AudioInputDevice?
    /// `nil` records no app audio.
    var app: CapturedApp?
    /// `nil` records no screen.
    var displayID: CGDirectDisplayID?
    var tagIDs: [UUID] = []
}

/// What a started recording actually captures, after any fallback.
struct CaptureSources: Equatable {
    /// `nil` when the system default microphone is recorded.
    var microphoneUID: String?
    var appBundleID: String?
    var displayID: CGDirectDisplayID?
}

struct CaptureStart {
    let session: RecordingSession
    let capture: CaptureSources
}

/// The one place recordings are started, paused, resumed and stopped, shared by the window, the
/// menu-bar item, app lifecycle and the extension API, so they cannot start two recordings or stop
/// one twice.
@MainActor
@Observable
final class CaptureCoordinator {
    enum Phase: Equatable {
        case idle
        case starting
        /// Also while a pause waits for the first microphone audio.
        case recording
        /// Also while a resume runs.
        case paused
        case stopping
    }

    /// Why a pause or resume did not happen.
    enum TransitionError: Error, Equatable {
        /// No recording is running or paused: idle, starting, stopping, or it ended during a pause's wait.
        case notRecording
        /// A resume or stop cancelled the pause while it waited for the first microphone audio.
        case cancelled
        /// Capture could not be restarted. The recording stays paused.
        case resumeFailed
    }

    enum StartOrigin {
        case window
        case menuBar
        /// The extension API. Only these starts run the readiness check.
        case api
    }

    enum StartError: Error, Equatable {
        case alreadyRecording
        case workspaceUnavailable
        case permissionMissing
        case modelsMissing
        /// Capture did not start. The view model holds the reason, as before.
        case notStarted
    }

    struct CurrentSession: Equatable {
        let id: UUID
        let title: String
        let startedAt: Date
        let tagIDs: [UUID]
        /// What is actually being captured, after any fallback.
        let capture: CaptureSources
    }

    /// The title of a menu-bar quick start.
    static let quickStartTitle = "Untitled Session"

    private let viewModel: NewSessionViewModel
    private let workspaceService: WorkspaceServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let menuBarSettings: MenuBarSettings
    private let modelsReady: @MainActor () -> Bool
    private let tagService = TagService()
    private let logger = Logger(subsystem: "Scriberman", category: "CaptureCoordinator")

    /// Discards the window's pending session, if there is one. Set by `AppState`.
    @ObservationIgnored var discardPendingSession: (@MainActor () -> Void)?

    private var transition: Phase?
    private var startedSession: CurrentSession?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var startResult: Result<CaptureStart, StartError>?
    @ObservationIgnored private var stopTask: Task<UUID?, Never>?
    /// The pause in flight, including its wait for the first microphone audio.
    @ObservationIgnored private var pauseTask: Task<Result<Void, TransitionError>, Never>?
    @ObservationIgnored private var resumeTask: Task<Result<Void, TransitionError>, Never>?

    init(
        viewModel: NewSessionViewModel,
        workspaceService: WorkspaceServiceProtocol,
        permissionService: PermissionServiceProtocol,
        menuBarSettings: MenuBarSettings,
        modelsReady: @escaping @MainActor () -> Bool
    ) {
        self.viewModel = viewModel
        self.workspaceService = workspaceService
        self.permissionService = permissionService
        self.menuBarSettings = menuBarSettings
        self.modelsReady = modelsReady
    }

    var phase: Phase {
        if let transition {
            return transition
        }
        if viewModel.isIdle {
            return .idle
        }
        return viewModel.isPaused ? .paused : .recording
    }

    /// True while a recording runs or is paused, with no start or stop under way.
    private var isRecordingOrPaused: Bool {
        transition == nil && !viewModel.isIdle
    }

    /// The recording under way, or nil while idle or starting.
    var current: CurrentSession? {
        switch phase {
        case .recording, .paused, .stopping:
            return startedSession
        case .idle, .starting:
            return nil
        }
    }

    /// Starts recording `choice`. Refused unless idle.
    func start(
        _ choice: CaptureChoice,
        origin: StartOrigin,
        context: ModelContext
    ) async -> Result<CaptureStart, StartError> {
        await run(origin: origin, context: context) { choice }
    }

    /// Starts recording as the menu-bar item always has: the pending session is discarded, the
    /// running apps refreshed, and the last-used microphone and app recorded under the default title.
    func quickStart(origin: StartOrigin, context: ModelContext) async -> Result<CaptureStart, StartError> {
        guard phase == .idle else { return .failure(.alreadyRecording) }
        discardPendingSession?()
        viewModel.refreshApps()

        let micDeviceUID = menuBarSettings.lastUsedMicUID
        let app = viewModel.runningApps.first { $0.bundleID == menuBarSettings.lastUsedAppBundleID }

        return await run(origin: origin, context: context) { [viewModel] in
            viewModel.applySelections(micDeviceUID: micDeviceUID, app: app)
            return viewModel.windowChoice(title: Self.quickStartTitle)
        }
    }

    /// Stops the recording under way, paused or not, and returns its session. A stop while
    /// stopping joins that stop; a stop while starting waits for the start first. A stop cancels a
    /// pause waiting for microphone audio, and waits for a resume.
    func stop(context: ModelContext) async -> RecordingSession? {
        if let startTask {
            await startTask.value
        }
        if let stopTask {
            return session(await stopTask.value, in: context)
        }

        transition = .stopping
        let pausing = pauseTask
        pausing?.cancel()
        let resuming = resumeTask
        let task = Task { [viewModel] in
            _ = await pausing?.value
            _ = await resuming?.value
            return await viewModel.stopRecording(context: context)?.id
        }
        stopTask = task
        let id = await task.value
        stopTask = nil
        transition = nil
        return session(id, in: context)
    }

    /// Pauses the recording. Succeeds when it is paused, including when it already was. Waits for
    /// the first microphone audio first; a resume or stop during that wait cancels it. A pause
    /// during a resume waits for it, then pauses. Refused unless a recording runs or is paused.
    func pause() async -> Result<Void, TransitionError> {
        if let resumeTask {
            _ = await resumeTask.value
        }
        guard isRecordingOrPaused else { return .failure(.notRecording) }
        if viewModel.isPaused {
            return .success(())
        }
        if let pauseTask {
            return await pauseTask.value
        }

        // Cleared by the task itself, so a request made after it ends never joins it.
        let task = Task { [weak self, viewModel] () -> Result<Void, TransitionError> in
            defer { self?.pauseTask = nil }
            guard await viewModel.waitForFirstMicAudio() else {
                return .failure(Task.isCancelled ? .cancelled : .notRecording)
            }
            guard !Task.isCancelled else { return .failure(.cancelled) }
            return await viewModel.pauseCapture() ? .success(()) : .failure(.notRecording)
        }
        pauseTask = task
        return await task.value
    }

    /// Resumes the recording. Succeeds when it runs, including when it was not paused. Cancels a
    /// pause that is still waiting for microphone audio. A resume during a resume joins it. A
    /// failed resume leaves the recording paused. Refused unless a recording runs or is paused.
    func resume() async -> Result<Void, TransitionError> {
        guard isRecordingOrPaused else { return .failure(.notRecording) }
        if let pauseTask {
            pauseTask.cancel()
            _ = await pauseTask.value
        }
        if let resumeTask {
            return await resumeTask.value
        }
        guard isRecordingOrPaused else { return .failure(.notRecording) }
        guard viewModel.isPaused else { return .success(()) }

        let task = Task { [weak self, viewModel] () -> Result<Void, TransitionError> in
            defer { self?.resumeTask = nil }
            return await viewModel.resumeCapture() ? .success(()) : .failure(.resumeFailed)
        }
        resumeTask = task
        return await task.value
    }

    private func run(
        origin: StartOrigin,
        context: ModelContext,
        choice makeChoice: @escaping @MainActor () -> CaptureChoice
    ) async -> Result<CaptureStart, StartError> {
        guard phase == .idle else { return .failure(.alreadyRecording) }
        transition = .starting
        startedSession = nil

        startResult = nil
        let task = Task { [weak self] in
            guard let self else { return }
            startResult = await performStart(origin: origin, context: context, choice: makeChoice)
        }
        startTask = task
        await task.value
        let result = startResult ?? .failure(.notStarted)
        startResult = nil
        startTask = nil
        transition = nil
        return result
    }

    private func performStart(
        origin: StartOrigin,
        context: ModelContext,
        choice makeChoice: @MainActor () -> CaptureChoice
    ) async -> Result<CaptureStart, StartError> {
        if origin == .api, let refusal = await readinessRefusal() {
            logger.notice("Refused an API start: \(String(describing: refusal), privacy: .public)")
            return .failure(refusal)
        }

        let choice = makeChoice()
        guard let started = await viewModel.startRecording(choice, context: context) else {
            return .failure(.notStarted)
        }

        let tagIDs = assignTags(choice.tagIDs, to: started.session, in: context)
        startedSession = CurrentSession(
            id: started.session.id,
            title: started.session.title,
            startedAt: viewModel.recordingStartedAt ?? started.session.createdAt,
            tagIDs: tagIDs,
            capture: started.capture
        )
        return .success(started)
    }

    private func readinessRefusal() async -> StartError? {
        do {
            _ = try await workspaceService.requireAuthorizedWorkspace()
        } catch {
            return .workspaceUnavailable
        }
        guard permissionService.micStatus == .granted else {
            return .permissionMissing
        }
        guard modelsReady() else {
            return .modelsMissing
        }
        return nil
    }

    /// Applies the chosen tags and returns the session's tags other than the default.
    private func assignTags(_ ids: [UUID], to session: RecordingSession, in context: ModelContext) -> [UUID] {
        for id in ids {
            let descriptor = FetchDescriptor<RecordingTag>(predicate: #Predicate { $0.id == id })
            guard let tag = try? context.fetch(descriptor).first else { continue }
            do {
                try tagService.assign(tag, to: session, in: context)
            } catch {
                logger.error("Assigning a tag at start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return session.tags.filter { !$0.isDefault }.map(\.id)
    }

    private func session(_ id: UUID?, in context: ModelContext) -> RecordingSession? {
        guard let id else { return nil }
        return try? RecordingSession.fetch(id: id, in: context)
    }
}
