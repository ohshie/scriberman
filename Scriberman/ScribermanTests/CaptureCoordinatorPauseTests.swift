import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// Pause and resume through the capture coordinator, and the view model's monitoring while paused.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CaptureCoordinatorPauseTests {
    private struct Fixture {
        let recordingService: MockRecordingService
        let appAudioService: MockAppAudioService
        let viewModel: NewSessionViewModel
        let coordinator: CaptureCoordinator
        let context: ModelContext
        let audioSyncStore: UserDefaults
        let cleanup: () -> Void

        /// Starts a recording. With `app`, the session captures app audio, which the idle prompt needs.
        @MainActor
        @discardableResult
        func start(app: Bool = false) async throws -> CaptureStart {
            var choice = CaptureChoice(title: "Paused")
            if app {
                let captured = CapturedApp(bundleID: "com.example.call", name: "Call", pid: 40, icon: nil)
                appAudioService.runningApps = [captured]
                choice.app = captured
            }
            return try await coordinator.start(choice, origin: .window, context: context).get()
        }
    }

    private func makeFixture(transcriber: any LiveTranscribing = IdleLiveTranscriber()) throws -> Fixture {
        let workspaceService = MockWorkspaceService()
        let recordingService = MockRecordingService()
        let appAudioService = MockAppAudioService()
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        let suiteName = "CaptureCoordinatorPauseTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)
        workspaceService.currentWorkspaceResult = workspace

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        recordingService.persistsSessionsIn = container
        recordingService.isRecordingOverride = true

        let viewModel = NewSessionViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: MockAudioDeviceService(),
            appAudioService: appAudioService,
            screenCaptureService: MockScreenCaptureService(),
            permissionService: permissionService,
            userInputIdleProvider: NoUserInput(),
            userDefaults: userDefaults,
            liveTranscriptionService: transcriber,
            audioSyncConfig: AudioSyncConfig(store: userDefaults)
        )
        let menuBarSettings = MenuBarSettings(userDefaults: userDefaults)
        viewModel.menuBarSettings = menuBarSettings
        let coordinator = CaptureCoordinator(
            viewModel: viewModel,
            workspaceService: workspaceService,
            permissionService: permissionService,
            menuBarSettings: menuBarSettings,
            modelsReady: { true }
        )
        return Fixture(
            recordingService: recordingService,
            appAudioService: appAudioService,
            viewModel: viewModel,
            coordinator: coordinator,
            context: ModelContext(container),
            audioSyncStore: userDefaults,
            cleanup: { userDefaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private struct NoUserInput: UserInputIdleProviding {
        func secondsSinceLastInput() -> TimeInterval? { nil }
    }

    private func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Lets the 50 ms monitor loop and any pending tasks run.
    private func settle(_ duration: Duration = .milliseconds(150)) async {
        try? await Task.sleep(for: duration)
    }

    /// Makes the pause wait for the first microphone audio: none written yet, and a start check
    /// that does not run during the test.
    private func holdFirstMicAudio(_ fixture: Fixture) {
        fixture.viewModel.startVerificationDelay = .seconds(600)
        fixture.recordingService.frameCountQueue = [(mic: 0, app: nil)]
    }

    // MARK: - Recording

    @Test
    func pauseAndResumeFromRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let started = try await fixture.start()

        #expect(await fixture.coordinator.pause().succeeded)
        #expect(fixture.coordinator.phase == .paused)
        #expect(fixture.coordinator.current?.id == started.session.id)
        #expect(fixture.viewModel.isPaused)
        #expect(fixture.viewModel.state == .recording)
        #expect(fixture.recordingService.pauseCallCount == 1)

        #expect(await fixture.coordinator.resume().succeeded)
        #expect(fixture.coordinator.phase == .recording)
        #expect(!fixture.viewModel.isPaused)
        #expect(fixture.viewModel.state == .recording)
        #expect(fixture.recordingService.resumeCallCount == 1)
    }

    @Test
    func resumeWhileRecordingSucceedsAndChangesNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()

        #expect(await fixture.coordinator.resume().succeeded)
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.recordingService.resumeCallCount == 0)
    }

    @Test
    func pauseWhilePausedSucceedsAndChangesNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        _ = await fixture.coordinator.pause()

        #expect(await fixture.coordinator.pause().succeeded)
        #expect(fixture.coordinator.phase == .paused)
        #expect(fixture.recordingService.pauseCallCount == 1)
    }

    @Test
    func stopWhilePausedSavesTheSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let started = try await fixture.start()
        _ = await fixture.coordinator.pause()

        let stopped = await fixture.coordinator.stop(context: fixture.context)

        #expect(stopped?.id == started.session.id)
        #expect(fixture.coordinator.phase == .idle)
        #expect(!fixture.viewModel.isPaused)
        #expect(fixture.viewModel.isIdle)
    }

    // MARK: - Starting, stopping, idle

    @Test
    func pauseAndResumeAreRefusedWhileIdle() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        #expect(await fixture.coordinator.pause().failure == .notRecording)
        #expect(await fixture.coordinator.resume().failure == .notRecording)
        #expect(fixture.recordingService.calls.isEmpty)
        #expect(fixture.coordinator.phase == .idle)
    }

    @Test
    func pauseAndResumeAreRefusedWhileStarting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let gate = AsyncGate()
        fixture.recordingService.startGate = gate
        let coordinator = fixture.coordinator
        let context = fixture.context
        let start = Task { await coordinator.start(CaptureChoice(title: "Starting"), origin: .window, context: context).succeeded }
        await gate.waitUntilHolding()
        #expect(coordinator.phase == .starting)

        #expect(await coordinator.pause().failure == .notRecording)
        #expect(await coordinator.resume().failure == .notRecording)
        await gate.open()
        #expect(await start.value)
        #expect(fixture.recordingService.calls.isEmpty)
        #expect(coordinator.phase == .recording)
    }

    @Test
    func pauseAndResumeAreRefusedWhileStopping() async throws {
        let transcriber = GatedStopLiveTranscriber()
        let fixture = try makeFixture(transcriber: transcriber)
        defer { fixture.cleanup() }
        try await fixture.start()
        await transcriber.waitUntilStarted()
        _ = await fixture.coordinator.pause()
        let coordinator = fixture.coordinator
        let context = fixture.context
        let stop = Task { await coordinator.stop(context: context)?.id }
        await transcriber.waitUntilStopping()
        #expect(coordinator.phase == .stopping)

        #expect(await coordinator.pause().failure == .notRecording)
        #expect(await coordinator.resume().failure == .notRecording)
        await transcriber.releaseStop()
        #expect(await stop.value != nil)
        #expect(fixture.recordingService.calls == ["pause", "stop"])
    }

    // MARK: - Pausing

    @Test
    func pauseWaitsForTheFirstMicrophoneAudio() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        holdFirstMicAudio(fixture)
        let coordinator = fixture.coordinator

        let pause = Task { await coordinator.pause().succeeded }
        await settle()
        #expect(coordinator.phase == .recording)
        #expect(!fixture.viewModel.isPaused)
        #expect(fixture.recordingService.pauseCallCount == 0)

        fixture.recordingService.frameCountQueue = [(mic: 960, app: nil)]
        #expect(await pause.value)
        #expect(coordinator.phase == .paused)
        #expect(fixture.recordingService.pauseCallCount == 1)
    }

    @Test
    func twoPausesWhileWaitingShareOnePause() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        holdFirstMicAudio(fixture)
        let coordinator = fixture.coordinator

        let first = Task { await coordinator.pause().succeeded }
        let second = Task { await coordinator.pause().succeeded }
        await settle()
        fixture.recordingService.frameCountQueue = [(mic: 960, app: nil)]

        #expect(await first.value)
        #expect(await second.value)
        #expect(fixture.recordingService.pauseCallCount == 1)
    }

    @Test
    func resumeWhileWaitingCancelsThePauseAndRecordingContinues() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        holdFirstMicAudio(fixture)
        let coordinator = fixture.coordinator
        let pause = Task { await coordinator.pause().failure }
        await settle()

        #expect(await coordinator.resume().succeeded)
        #expect(await pause.value == .cancelled)
        fixture.recordingService.frameCountQueue = [(mic: 960, app: nil)]
        await settle()
        #expect(coordinator.phase == .recording)
        #expect(fixture.recordingService.calls.isEmpty)
    }

    @Test
    func aPauseRightAfterAResumeCancelledTheWaitPausesAgain() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        holdFirstMicAudio(fixture)
        let coordinator = fixture.coordinator
        let cancelled = Task { await coordinator.pause().failure }
        await settle()

        _ = await coordinator.resume()
        fixture.recordingService.frameCountQueue = [(mic: 960, app: nil)]
        let again = await coordinator.pause()

        #expect(again.succeeded)
        #expect(await cancelled.value == .cancelled)
        #expect(coordinator.phase == .paused)
    }

    @Test
    func stopWhileWaitingCancelsThePauseAndStops() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let started = try await fixture.start()
        holdFirstMicAudio(fixture)
        let coordinator = fixture.coordinator
        let pause = Task { await coordinator.pause().failure }
        await settle()

        let stopped = await coordinator.stop(context: fixture.context)

        #expect(stopped?.id == started.session.id)
        #expect(await pause.value == .cancelled)
        #expect(fixture.recordingService.calls == ["stop"])
        #expect(coordinator.phase == .idle)
    }

    @Test
    func aPauseIsRefusedWhenTheRecordingEndsWhileWaiting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        holdFirstMicAudio(fixture)
        let coordinator = fixture.coordinator
        let pause = Task { await coordinator.pause().failure }
        await settle()

        fixture.recordingService.isRecordingOverride = false

        #expect(await pause.value == .notRecording)
        #expect(fixture.recordingService.pauseCallCount == 0)
    }

    @Test
    func aStartThatPassedOnAppAudioAlonePausesWithoutMicrophoneAudio() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.recordingService.frameCountQueue = [(mic: 0, app: 960)]
        try await fixture.start(app: true)
        await settle()

        #expect(await fixture.coordinator.pause().succeeded)
        #expect(fixture.coordinator.phase == .paused)
    }

    @Test
    func appAudioAloneDoesNotEndTheWaitBeforeTheStartCheck() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .seconds(600)
        fixture.recordingService.frameCountQueue = [(mic: 0, app: 960)]
        try await fixture.start(app: true)
        let coordinator = fixture.coordinator

        let pause = Task { await coordinator.pause().succeeded }
        await settle()
        #expect(fixture.recordingService.pauseCallCount == 0)

        fixture.recordingService.frameCountQueue = [(mic: 960, app: 960)]
        #expect(await pause.value)
    }

    @Test
    func theRecorderFallbackPausesWithoutWaiting() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .seconds(600)
        fixture.recordingService.frameCountQueue = [(mic: nil, app: nil)]
        try await fixture.start()

        #expect(await fixture.coordinator.pause().succeeded)
        #expect(fixture.coordinator.phase == .paused)
    }

    // MARK: - Resuming

    @Test
    func twoResumesShareOneResume() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        _ = await fixture.coordinator.pause()
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let coordinator = fixture.coordinator

        let first = Task { await coordinator.resume().succeeded }
        await gate.waitUntilHolding()
        #expect(coordinator.phase == .paused)
        let second = Task { await coordinator.resume().succeeded }
        await settle(.milliseconds(30))
        await gate.open()

        #expect(await first.value)
        #expect(await second.value)
        #expect(fixture.recordingService.resumeCallCount == 1)
        #expect(coordinator.phase == .recording)
    }

    @Test
    func aPauseDuringAResumeWaitsForItThenPauses() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        _ = await fixture.coordinator.pause()
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let coordinator = fixture.coordinator

        let resume = Task { await coordinator.resume().succeeded }
        await gate.waitUntilHolding()
        let pause = Task { await coordinator.pause().succeeded }
        await settle(.milliseconds(30))
        #expect(fixture.recordingService.pauseCallCount == 1)
        await gate.open()

        #expect(await resume.value)
        #expect(await pause.value)
        #expect(fixture.recordingService.calls == ["pause", "resume", "resumed", "pause"])
        #expect(coordinator.phase == .paused)
    }

    @Test
    func aPauseDuringAResumeThatFailsSucceedsWithoutPausingAgain() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        _ = await fixture.coordinator.pause()
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        fixture.recordingService.resumeResult = false
        let coordinator = fixture.coordinator

        let resume = Task { await coordinator.resume().failure }
        await gate.waitUntilHolding()
        let pause = Task { await coordinator.pause().succeeded }
        await settle(.milliseconds(30))
        await gate.open()

        #expect(await resume.value == .resumeFailed)
        #expect(await pause.value)
        #expect(fixture.recordingService.pauseCallCount == 1)
        #expect(coordinator.phase == .paused)
    }

    @Test
    func aStopDuringAResumeWaitsForItThenStops() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let started = try await fixture.start()
        _ = await fixture.coordinator.pause()
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let coordinator = fixture.coordinator
        let context = fixture.context

        let resume = Task { await coordinator.resume().succeeded }
        await gate.waitUntilHolding()
        let stop = Task { await coordinator.stop(context: context)?.id }
        await settle(.milliseconds(30))
        #expect(!fixture.recordingService.calls.contains("stop"))
        await gate.open()

        #expect(await resume.value)
        #expect(await stop.value == started.session.id)
        #expect(fixture.recordingService.calls == ["pause", "resume", "resumed", "stop"])
        #expect(coordinator.phase == .idle)
    }

    @Test
    func aFailedResumeStaysPausedWithItsErrorAndARetryClearsIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        _ = await fixture.coordinator.pause()
        fixture.recordingService.resumeResult = false

        #expect(await fixture.coordinator.resume().failure == .resumeFailed)
        #expect(fixture.coordinator.phase == .paused)
        #expect(fixture.viewModel.isPaused)
        #expect(fixture.viewModel.resumeFailureMessage == "Recording could not be resumed.")

        fixture.recordingService.resumeResult = true
        #expect(await fixture.coordinator.resume().succeeded)
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.viewModel.resumeFailureMessage == nil)
    }

    // MARK: - Elapsed time

    @Test
    func elapsedTimeExcludesPauses() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        fixture.viewModel.clock = { now }
        try await fixture.start()

        now = now.addingTimeInterval(10)
        await waitUntil { fixture.viewModel.elapsedTime == 10 }
        #expect(fixture.viewModel.elapsedTime == 10)

        _ = await fixture.coordinator.pause()
        now = now.addingTimeInterval(30)
        await settle()
        #expect(fixture.viewModel.elapsedTime == 10)

        _ = await fixture.coordinator.resume()
        now = now.addingTimeInterval(5)
        await waitUntil { fixture.viewModel.elapsedTime == 15 }
        #expect(fixture.viewModel.elapsedTime == 15)
    }

    // MARK: - Meters

    @Test
    func meterLevelsReadZeroWhilePaused() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.recordingService.audioLevelsOverride = (mic: 0.6, app: 0.4)
        try await fixture.start(app: true)
        await waitUntil { fixture.viewModel.meterLevels.mic > 0 }
        #expect(fixture.viewModel.meterLevels.mic > 0)

        _ = await fixture.coordinator.pause()
        await settle()
        #expect(fixture.viewModel.meterLevels.mic == 0)
        #expect(fixture.viewModel.meterLevels.app == 0)

        _ = await fixture.coordinator.resume()
        await waitUntil { fixture.viewModel.meterLevels.mic > 0 }
        #expect(fixture.viewModel.meterLevels.mic > 0)
    }

    // MARK: - Toggle

    /// The app's pause/resume controls are one toggle: it pauses a running recording and resumes a
    /// paused one.
    @Test
    func toggleAlternatesBetweenPauseAndResume() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()

        #expect(await fixture.coordinator.pauseOrResume().succeeded)
        #expect(fixture.coordinator.phase == .paused)
        #expect(await fixture.coordinator.pauseOrResume().succeeded)
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.recordingService.pauseCallCount == 1)
        #expect(fixture.recordingService.resumeCallCount == 1)
    }

    @Test
    func toggleIsRefusedWithNoRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        #expect(await fixture.coordinator.pauseOrResume().failure == .notRecording)
    }

    // MARK: - Phase

    @Test(arguments: [
        (CaptureCoordinator.Phase.idle, false),
        (.starting, false),
        (.recording, true),
        (.paused, true),
        (.stopping, false),
    ])
    func onlyARunningOrPausedRecordingCanBePausedOrResumed(phase: CaptureCoordinator.Phase, expected: Bool) {
        #expect(phase.canPauseOrResume == expected)
    }

    // MARK: - Capture health

    private func enableCaptureHealth(_ fixture: Fixture, stallThreshold: TimeInterval) {
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        fixture.viewModel.captureHealthConfiguration = CaptureHealthMonitor.Configuration(
            stallThreshold: stallThreshold,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
        fixture.audioSyncStore.set(true, forKey: AudioSyncConfig.FlagDefinitions.shipped.captureHealthRecovery.key)
    }

    @Test
    func captureHealthIsNotEvaluatedWhilePaused() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        enableCaptureHealth(fixture, stallThreshold: 60)
        try await fixture.start()
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 2 }

        _ = await fixture.coordinator.pause()
        await settle(.milliseconds(30))
        let whilePaused = fixture.recordingService.captureHealthSnapshotCallCount
        await settle()
        #expect(fixture.recordingService.captureHealthSnapshotCallCount == whilePaused)

        _ = await fixture.coordinator.resume()
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount > whilePaused + 1 }
        #expect(fixture.recordingService.captureHealthSnapshotCallCount > whilePaused + 1)
    }

    @Test
    func aLongPauseDoesNotMakeTheMicrophoneLookStalledAtResume() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        enableCaptureHealth(fixture, stallThreshold: 0.5)
        // Frames advance while recording and stand still from the pause on.
        var frames: Int64 = 0
        var advancing = true
        fixture.recordingService.captureHealthSnapshotProvider = {
            if advancing { frames += 960 }
            return CaptureHealthMonitor.Snapshot(micFrames: frames, appFrames: nil)
        }
        try await fixture.start()
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 3 }

        advancing = false
        _ = await fixture.coordinator.pause()
        await settle(.seconds(1))
        _ = await fixture.coordinator.resume()
        let resumedAt = fixture.recordingService.captureHealthSnapshotCallCount
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= resumedAt + 5 }
        await settle(.milliseconds(100))

        #expect(fixture.recordingService.restartAudioCaptureInPlaceCallCount == 0)
        #expect(fixture.viewModel.lastCaptureHealthEffect == .none)
    }

    @Test
    func aFailureResumeHandledIsNotRestartedAgain() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        enableCaptureHealth(fixture, stallThreshold: 60)
        var frames: Int64 = 0
        var failures = 0
        var handled = 0
        fixture.recordingService.captureHealthSnapshotProvider = {
            frames += 960
            return CaptureHealthMonitor.Snapshot(
                micFrames: frames, appFrames: nil, streamFailureCount: failures, handledStreamFailureCount: handled
            )
        }
        try await fixture.start()
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 2 }

        _ = await fixture.coordinator.pause()
        failures = 1
        handled = 1
        _ = await fixture.coordinator.resume()
        let resumedAt = fixture.recordingService.captureHealthSnapshotCallCount
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= resumedAt + 5 }

        #expect(fixture.recordingService.restartAudioCaptureInPlaceCallCount == 0)
    }

    // MARK: - Idle prompt

    private func idleSettings(threshold: TimeInterval, allIdle: Bool = true, autoStop: Bool = false) -> IdlePromptSettings {
        IdlePromptSettings(
            isEnabled: true,
            watchAppAudio: true,
            watchMicAudio: true,
            watchUserInput: false,
            requiresAllSourcesIdle: allIdle,
            idleThreshold: threshold,
            autoStopEnabled: autoStop,
            autoStopDelay: 0.05
        )
    }

    @Test(arguments: [true, false])
    func theIdlePromptAppearsDuringAPauseAndAResumeClosesIt(allIdle: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let rules = idleSettings(threshold: 0.4, allIdle: allIdle)
        fixture.viewModel.idlePromptPreferencesProvider = { rules }
        // Both sources were last active at the start; nothing heard while paused counts.
        let startedAt = Date()
        fixture.recordingService.activityTimestampsOverride = (startedAt, startedAt)
        try await fixture.start(app: true)
        _ = await fixture.coordinator.pause()

        await waitUntil { fixture.viewModel.isIdlePromptVisible }
        #expect(fixture.viewModel.isIdlePromptVisible)

        _ = await fixture.coordinator.resume()
        await waitUntil { !fixture.viewModel.isIdlePromptVisible }
        #expect(!fixture.viewModel.isIdlePromptVisible)
        await settle(.milliseconds(200))
        #expect(!fixture.viewModel.isIdlePromptVisible)
    }

    @Test
    func theIdleAutoStopStopsAPausedRecording() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let rules = idleSettings(threshold: 0.1, autoStop: true)
        fixture.viewModel.idlePromptPreferencesProvider = { rules }
        let coordinator = fixture.coordinator
        let context = fixture.context
        var stopped: UUID?
        fixture.viewModel.onIdlePromptStopRequested = { stopped = await coordinator.stop(context: context)?.id }
        let started = try await fixture.start(app: true)
        _ = await coordinator.pause()

        await waitUntil { stopped != nil }

        #expect(stopped == started.session.id)
        #expect(coordinator.phase == .idle)
    }

    // MARK: - Lifecycle

    @Test
    func aPausedRecordingStillCountsAsRecordingForLifecycleChecks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try await fixture.start()
        _ = await fixture.coordinator.pause()

        // Sleep, quit and the menu read `.recording`; the calendar reads `isIdle`.
        #expect(fixture.viewModel.state == .recording)
        #expect(!fixture.viewModel.isIdle)
    }
}

private extension Result where Failure == CaptureCoordinator.TransitionError {
    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }

    var failure: CaptureCoordinator.TransitionError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

private extension Result where Success == CaptureStart, Failure == CaptureCoordinator.StartError {
    var succeeded: Bool {
        if case .success = self { return true }
        return false
    }
}
