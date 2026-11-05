import CoreAudio
import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct CaptureCoordinatorTests {
    private struct Fixture {
        let workspaceService: MockWorkspaceService
        let recordingService: MockRecordingService
        let audioDeviceService: MockAudioDeviceService
        let appAudioService: MockAppAudioService
        let screenCaptureService: MockScreenCaptureService
        let permissionService: MockPermissionService
        let menuBarSettings: MenuBarSettings
        let viewModel: NewSessionViewModel
        let coordinator: CaptureCoordinator
        let container: ModelContainer
        let context: ModelContext
        let readiness: ReadinessState
        let cleanup: () -> Void
    }

    @MainActor
    private final class ReadinessState {
        var modelsReady = true
        var discardedPendingSessions = 0
    }

    private func makeFixture(transcriber: any LiveTranscribing = IdleLiveTranscriber()) throws -> Fixture {
        let workspaceService = MockWorkspaceService()
        let recordingService = MockRecordingService()
        let audioDeviceService = MockAudioDeviceService()
        let appAudioService = MockAppAudioService()
        let screenCaptureService = MockScreenCaptureService()
        let permissionService = MockPermissionService()
        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        let suiteName = "CaptureCoordinatorTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)
        workspaceService.currentWorkspaceResult = workspace

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        recordingService.persistsSessionsIn = container
        recordingService.isRecordingOverride = true

        let viewModel = NewSessionViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            screenCaptureService: screenCaptureService,
            permissionService: permissionService,
            userDefaults: userDefaults,
            liveTranscriptionService: transcriber,
            audioSyncConfig: AudioSyncConfig(store: userDefaults)
        )
        let menuBarSettings = MenuBarSettings(userDefaults: userDefaults)
        viewModel.menuBarSettings = menuBarSettings
        let readiness = ReadinessState()
        let coordinator = CaptureCoordinator(
            viewModel: viewModel,
            workspaceService: workspaceService,
            permissionService: permissionService,
            menuBarSettings: menuBarSettings,
            modelsReady: { readiness.modelsReady }
        )
        coordinator.discardPendingSession = { readiness.discardedPendingSessions += 1 }

        return Fixture(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            screenCaptureService: screenCaptureService,
            permissionService: permissionService,
            menuBarSettings: menuBarSettings,
            viewModel: viewModel,
            coordinator: coordinator,
            container: container,
            context: context,
            readiness: readiness,
            cleanup: { userDefaults.removePersistentDomain(forName: suiteName) }
        )
    }

    @Test
    func aStartRecordsTheChosenSessionAndReportsItAsCurrent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let result = await fixture.coordinator.start(
            CaptureChoice(title: "Standup"),
            origin: .window,
            context: fixture.context
        )

        let started = try result.get()
        #expect(started.session.title == "Standup")
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.coordinator.current?.id == started.session.id)
        #expect(fixture.coordinator.current?.title == "Standup")
    }
    // MARK: - One recording at a time

    @Test
    func twoStartsAtOnceGiveOneSessionAndOneRefusal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let coordinator = fixture.coordinator
        let context = fixture.context
        let first = Task { await coordinator.start(CaptureChoice(title: "First"), origin: .window, context: context).outcome }
        let second = Task { await coordinator.start(CaptureChoice(title: "Second"), origin: .api, context: context).outcome }
        let results = [await first.value, await second.value]

        let started = results.compactMap(\.sessionID)
        let refusals = results.compactMap(\.refusal)
        #expect(started.count == 1)
        #expect(refusals == [.alreadyRecording])
        #expect(fixture.recordingService.startCalls.count == 1)
        #expect(try fixture.context.fetch(FetchDescriptor<RecordingSession>()).count == 1)
    }

    @Test
    func aStartWhileRecordingIsRefused() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.coordinator.start(CaptureChoice(title: "First"), origin: .window, context: fixture.context).get()

        let quick = await fixture.coordinator.quickStart(origin: .menuBar, context: fixture.context)
        let api = await fixture.coordinator.start(CaptureChoice(title: "Second"), origin: .api, context: fixture.context)

        #expect(quick.refusal == .alreadyRecording)
        #expect(api.refusal == .alreadyRecording)
        #expect(fixture.readiness.discardedPendingSessions == 0)
        #expect(fixture.recordingService.startCalls.count == 1)
    }

    @Test
    func aStartWhileStoppingIsRefusedAndASecondStopJoinsTheFirst() async throws {
        let transcriber = GatedStopLiveTranscriber()
        let fixture = try makeFixture(transcriber: transcriber)
        defer { fixture.cleanup() }
        let started = try await fixture.coordinator.start(CaptureChoice(title: "Call"), origin: .window, context: fixture.context).get()
        await transcriber.waitUntilStarted()

        let firstStop = Task { await fixture.coordinator.stop(context: fixture.context)?.id }
        await transcriber.waitUntilStopping()
        #expect(fixture.coordinator.phase == .stopping)
        #expect(fixture.coordinator.current?.id == started.session.id)

        let refused = await fixture.coordinator.start(CaptureChoice(title: "Next"), origin: .api, context: fixture.context)
        let secondStop = Task { await fixture.coordinator.stop(context: fixture.context)?.id }
        await Task.yield()
        await transcriber.releaseStop()

        #expect(refused.refusal == .alreadyRecording)
        #expect(await firstStop.value == started.session.id)
        #expect(await secondStop.value == started.session.id)
        #expect(fixture.coordinator.phase == .idle)
        #expect(fixture.coordinator.current == nil)
        #expect(fixture.recordingService.startCalls.count == 1)
    }

    @Test
    func aStopWhileIdleReturnsNoSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        #expect(await fixture.coordinator.stop(context: fixture.context) == nil)
        #expect(fixture.coordinator.phase == .idle)
    }

    // MARK: - Selections

    @Test
    func aStartRecordsItsOwnChoiceAndLeavesTheWindowSelectionsAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let windowMic = AudioInputDevice(id: 1, uid: "mic-window", name: "Window Mic")
        let apiMic = AudioInputDevice(id: 2, uid: "mic-api", name: "API Mic")
        let windowApp = CapturedApp(bundleID: "com.example.window", name: "Window App", pid: 10, icon: nil)
        let apiApp = CapturedApp(bundleID: "com.example.api", name: "API App", pid: 20, icon: nil)
        fixture.audioDeviceService.availableDevices = [windowMic, apiMic]
        fixture.appAudioService.runningApps = [windowApp, apiApp]
        fixture.viewModel.selectedDevice = windowMic
        fixture.viewModel.selectApp(windowApp)

        let started = try await fixture.coordinator.start(
            CaptureChoice(title: "API", microphone: apiMic, app: apiApp),
            origin: .api,
            context: fixture.context
        ).get()

        let call = try #require(fixture.recordingService.startCalls.first)
        #expect(call.micDeviceID == 2)
        #expect(call.appProcessID == 20)
        #expect(call.title == "API")
        #expect(started.capture == CaptureSources(microphoneUID: "mic-api", appBundleID: "com.example.api", displayID: nil))
        #expect(fixture.viewModel.selectedDevice == windowMic)
        #expect(fixture.viewModel.selectedApp == windowApp)
    }

    @Test
    func aWindowStartRecordsTheWindowSelections() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let mic = AudioInputDevice(id: 3, uid: "mic-desk", name: "Desk Mic")
        let app = CapturedApp(bundleID: "com.example.call", name: "Call", pid: 30, icon: nil)
        fixture.audioDeviceService.availableDevices = [mic]
        fixture.appAudioService.runningApps = [app]
        fixture.viewModel.selectedDevice = mic
        fixture.viewModel.selectApp(app)

        let started = try await fixture.coordinator.start(
            fixture.viewModel.windowChoice(title: "Window"),
            origin: .window,
            context: fixture.context
        ).get()

        let call = try #require(fixture.recordingService.startCalls.first)
        #expect(call.micDeviceID == 3)
        #expect(call.appProcessID == 30)
        #expect(started.capture == CaptureSources(microphoneUID: "mic-desk", appBundleID: "com.example.call", displayID: nil))
    }

    // MARK: - Readiness

    @Test
    func anAPIStartIsRefusedWhenModelsAreMissing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.readiness.modelsReady = false

        let result = await fixture.coordinator.start(CaptureChoice(title: "API"), origin: .api, context: fixture.context)

        #expect(result.refusal == .modelsMissing)
        #expect(fixture.recordingService.startCalls.isEmpty)
        #expect(fixture.coordinator.phase == .idle)
    }

    @Test
    func anAPIStartIsRefusedWithoutAWorkspace() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.workspaceService.requireWritableResult = .failure(.notConfigured)

        let result = await fixture.coordinator.start(CaptureChoice(title: "API"), origin: .api, context: fixture.context)

        #expect(result.refusal == .workspaceUnavailable)
        #expect(fixture.recordingService.startCalls.isEmpty)
    }

    @Test
    func anAPIStartIsRefusedWithoutMicrophonePermission() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.permissionService.micStatus = .denied

        let result = await fixture.coordinator.start(CaptureChoice(title: "API"), origin: .api, context: fixture.context)

        #expect(result.refusal == .permissionMissing)
        #expect(fixture.recordingService.startCalls.isEmpty)
    }

    @Test
    func windowAndMenuBarStartsRecordWhenModelsAreMissing() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.readiness.modelsReady = false

        _ = try await fixture.coordinator.start(CaptureChoice(title: "Window"), origin: .window, context: fixture.context).get()
        _ = await fixture.coordinator.stop(context: fixture.context)
        _ = try await fixture.coordinator.quickStart(origin: .menuBar, context: fixture.context).get()

        #expect(fixture.recordingService.startCalls.count == 2)
    }

    // MARK: - Fallback report

    @Test
    func theStartReportsMicrophoneOnlyWhenAppAudioFallsBack() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let mic = AudioInputDevice(id: 4, uid: "mic-usb", name: "USB Mic")
        let app = CapturedApp(bundleID: "com.example.call", name: "Call", pid: 40, icon: nil)
        fixture.audioDeviceService.availableDevices = [mic]
        fixture.appAudioService.runningApps = [app]
        fixture.recordingService.startThrowSequence = [.failedToStart("tap")]

        let started = try await fixture.coordinator.start(
            CaptureChoice(title: "API", microphone: mic, app: app),
            origin: .api,
            context: fixture.context
        ).get()

        #expect(started.capture == CaptureSources(microphoneUID: "mic-usb", appBundleID: nil, displayID: nil))
        #expect(fixture.recordingService.startCalls.last?.appProcessID == nil)
    }

    @Test
    func theStartReportsTheDefaultMicrophoneWhenTheChosenOneFails() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let mic = AudioInputDevice(id: 5, uid: "mic-gone", name: "Gone Mic")
        fixture.audioDeviceService.availableDevices = [mic]
        fixture.recordingService.startThrowSequence = [.failedToStart("device")]

        let started = try await fixture.coordinator.start(
            CaptureChoice(title: "API", microphone: mic),
            origin: .api,
            context: fixture.context
        ).get()

        #expect(started.capture == CaptureSources(microphoneUID: nil, appBundleID: nil, displayID: nil))
    }

    @Test
    func theStartReportsNoScreenWhenScreenCaptureDoesNotStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.recordingService.screenCaptureActiveOverride = false

        let started = try await fixture.coordinator.start(
            CaptureChoice(title: "API", displayID: 77),
            origin: .api,
            context: fixture.context
        ).get()

        #expect(fixture.recordingService.startCalls.first?.captureDisplayID == 77)
        #expect(started.capture.displayID == nil)
    }

    @Test
    func theStartReportsTheScreenWhenItIsCaptured() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let started = try await fixture.coordinator.start(
            CaptureChoice(title: "API", displayID: 77),
            origin: .api,
            context: fixture.context
        ).get()

        #expect(started.capture.displayID == 77)
    }

    // MARK: - Tags

    @Test
    func theChosenTagsAreAppliedAndReportedAsCurrent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let tag = RecordingTag(name: "Work", colorHex: "336699")
        fixture.context.insert(tag)
        try fixture.context.save()

        let started = try await fixture.coordinator.start(
            CaptureChoice(title: "Tagged", tagIDs: [tag.id]),
            origin: .api,
            context: fixture.context
        ).get()

        #expect(started.session.tags.map(\.id) == [tag.id])
        #expect(fixture.coordinator.current?.tagIDs == [tag.id])
    }

    // MARK: - Quick start

    @Test
    func quickStartRecordsTheLastUsedMicrophoneAndAppUnderTheDefaultTitle() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let mic = AudioInputDevice(id: 6, uid: "mic-last", name: "Last Mic")
        let app = CapturedApp(bundleID: "com.example.last", name: "Last App", pid: 60, icon: nil)
        fixture.audioDeviceService.availableDevices = [mic]
        fixture.appAudioService.runningApps = [app]
        fixture.menuBarSettings.lastUsedMicUID = "mic-last"
        fixture.menuBarSettings.lastUsedAppBundleID = "com.example.last"

        let started = try await fixture.coordinator.quickStart(origin: .menuBar, context: fixture.context).get()

        #expect(fixture.readiness.discardedPendingSessions == 1)
        #expect(fixture.appAudioService.refreshCalls > 0)
        let call = try #require(fixture.recordingService.startCalls.first)
        #expect(call.micDeviceID == 6)
        #expect(call.appProcessID == 60)
        #expect(call.capturedAppName == "Last App")
        #expect(call.captureDisplayID == nil)
        #expect(call.title == "Untitled Session")
        #expect(started.session.title == "Untitled Session")
        #expect(started.capture == CaptureSources(microphoneUID: "mic-last", appBundleID: "com.example.last", displayID: nil))
    }

    @Test
    func quickStartWithNoLastUsedSelectionsRecordsTheDefaultMicrophoneAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.appAudioService.runningApps = [CapturedApp(bundleID: "com.example.other", name: "Other", pid: 70, icon: nil)]

        _ = try await fixture.coordinator.quickStart(origin: .menuBar, context: fixture.context).get()

        let call = try #require(fixture.recordingService.startCalls.first)
        #expect(call.micDeviceID == nil)
        #expect(call.appProcessID == nil)
    }
}

private extension Result where Success == CaptureStart, Failure == CaptureCoordinator.StartError {
    var refusal: CaptureCoordinator.StartError? {
        if case .failure(let error) = self { return error }
        return nil
    }

    /// The result reduced to values that can leave the main actor.
    var outcome: StartOutcome {
        switch self {
        case .success(let started): StartOutcome(sessionID: started.session.id, refusal: nil)
        case .failure(let error): StartOutcome(sessionID: nil, refusal: error)
        }
    }
}

private struct StartOutcome: Sendable {
    let sessionID: UUID?
    let refusal: CaptureCoordinator.StartError?
}

/// A live transcriber whose stop waits to be released, so a test can act while a stop is under way.
private actor GatedStopLiveTranscriber: LiveTranscribing {
    private var results: AsyncStream<TranscriptSegment>.Continuation?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var isStopping = false

    func prepare(workspace: Workspace, config: LiveTranscriptionPipelineSettings) async {}
    func start(workspace: Workspace, config: LiveTranscriptionPipelineSettings, resultContinuation: AsyncStream<TranscriptSegment>.Continuation) async throws {
        results = resultContinuation
        startWaiter?.resume()
        startWaiter = nil
    }
    func process(_ chunk: LiveAudioChunk, anchor: HostNanoseconds?) async {}
    func waitUntilStarted() async {
        if results != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func waitUntilStopping() async {
        if isStopping { return }
        await withCheckedContinuation { stopWaiter = $0 }
    }
    func releaseStop() {
        release?.resume()
        release = nil
    }
    func stop() async -> LiveSessionResult {
        isStopping = true
        stopWaiter?.resume()
        stopWaiter = nil
        await withCheckedContinuation { release = $0 }
        results?.finish()
        return LiveSessionResult(segments: [])
    }
}

/// A live transcriber that does nothing, so a test's recording never loads models.
private actor IdleLiveTranscriber: LiveTranscribing {
    private var results: AsyncStream<TranscriptSegment>.Continuation?

    func prepare(workspace: Workspace, config: LiveTranscriptionPipelineSettings) async {}
    func start(workspace: Workspace, config: LiveTranscriptionPipelineSettings, resultContinuation: AsyncStream<TranscriptSegment>.Continuation) async throws {
        results = resultContinuation
    }
    func process(_ chunk: LiveAudioChunk, anchor: HostNanoseconds?) async {}
    func stop() async -> LiveSessionResult {
        results?.finish()
        return LiveSessionResult(segments: [])
    }
}
