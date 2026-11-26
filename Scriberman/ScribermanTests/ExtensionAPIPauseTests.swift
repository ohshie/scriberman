import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// `POST /v1/recordings/pause` and `/resume`, and the `paused` state, through signed requests to
/// the handler with a real capture coordinator over mock capture services.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExtensionAPIPauseTests {
    typealias Fixture = ExtensionAPIRecordingTests.Fixture
    typealias StatusBody = ExtensionAPIRecordingTests.StatusBody
    typealias StartBody = ExtensionAPIRecordingTests.StartBody
    typealias SessionBody = ExtensionAPIRecordingTests.SessionBody

    struct TransitionBody: Decodable {
        let session: SessionBody
    }

    struct DetailBody: Decodable {
        let id: String
        let transcript: String?
    }

    nonisolated static let transitionRoutes = ["/v1/recordings/pause", "/v1/recordings/resume"]

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        try JSONDecoder().decode(type, from: response.body)
    }

    private func makeFixture(transcriber: any LiveTranscribing = IdleLiveTranscriber()) async throws -> Fixture {
        let fixture = try Fixture(transcriber: transcriber)
        try await fixture.pair()
        return fixture
    }

    @discardableResult
    private func start(_ fixture: Fixture) async throws -> SessionBody {
        let response = await fixture.send("POST", "/v1/recordings", json: #"{"title": "Call"}"#)
        try #require(response.status == 200)
        return try decode(StartBody.self, response).session
    }

    private func state(_ fixture: Fixture) async throws -> String {
        try decode(StatusBody.self, await fixture.send("GET", "/v1/status")).state
    }

    /// Makes a pause wait for the first microphone audio: none written, and a start check that
    /// does not run during the test. Set before the recording starts.
    private func holdFirstMicAudio(_ fixture: Fixture) {
        fixture.viewModel.startVerificationDelay = .seconds(600)
        fixture.recordingService.frameCountQueue = [(mic: 0, app: nil)]
    }

    /// Gives requests sent in tasks time to pass the handler and reach the coordinator, where a
    /// second one joins the operation under way.
    private func letRequestsArrive() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Recording

    @Test
    func pauseWhileRecordingPausesAndAnswersTheSession() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)

        let response = await fixture.send("POST", "/v1/recordings/pause")

        #expect(response.status == 200)
        #expect(try decode(TransitionBody.self, response).session == started)
        #expect(fixture.coordinator.phase == .paused)
        #expect(fixture.recordingService.pauseCallCount == 1)
    }

    @Test
    func resumeWhileRecordingSucceedsAndChangesNothing() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)

        let response = await fixture.send("POST", "/v1/recordings/resume")

        #expect(response.status == 200)
        #expect(try decode(TransitionBody.self, response).session == started)
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.recordingService.resumeCallCount == 0)
    }

    // MARK: - Paused

    @Test
    func statusWhilePausedReportsPausedWithTheSessionAndCapture() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)

        let response = await fixture.send("GET", "/v1/status")

        #expect(response.status == 200)
        let body = try decode(StatusBody.self, response)
        #expect(body.state == "paused")
        #expect(body.session == started)
        #expect(body.capture == ExtensionAPIRecordingTests.CaptureBody(microphoneUid: nil, appBundleId: nil, displayId: nil))
    }

    @Test
    func resumeWhilePausedResumesAndAnswersTheSession() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)

        let response = await fixture.send("POST", "/v1/recordings/resume")

        #expect(response.status == 200)
        #expect(try decode(TransitionBody.self, response).session == started)
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.recordingService.resumeCallCount == 1)
        #expect(try await state(fixture) == "recording")
    }

    @Test
    func pauseWhilePausedSucceedsAndChangesNothing() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)

        let response = await fixture.send("POST", "/v1/recordings/pause")

        #expect(response.status == 200)
        #expect(try decode(TransitionBody.self, response).session == started)
        #expect(fixture.coordinator.phase == .paused)
        #expect(fixture.recordingService.pauseCallCount == 1)
    }

    @Test
    func pauseAndResumeCanRepeat() async throws {
        let fixture = try await makeFixture()
        try await start(fixture)

        for _ in 0..<3 {
            #expect(await fixture.send("POST", "/v1/recordings/pause").status == 200)
            #expect(try await state(fixture) == "paused")
            #expect(await fixture.send("POST", "/v1/recordings/resume").status == 200)
            #expect(try await state(fixture) == "recording")
        }
        #expect(fixture.recordingService.pauseCallCount == 3)
        #expect(fixture.recordingService.resumeCallCount == 3)
    }

    @Test
    func aFailedResumeIsReportedAndTheRecordingStaysPaused() async throws {
        let fixture = try await makeFixture()
        try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        fixture.recordingService.resumeResult = false

        let response = await fixture.send("POST", "/v1/recordings/resume")

        #expect(response.status == 500)
        let error = try decode(ExtensionAPIErrorBody.self, response)
        #expect(error.code == "resume_failed")
        #expect(error.message == NewSessionViewModel.resumeFailedMessage)
        #expect(fixture.coordinator.phase == .paused)
        #expect(try await state(fixture) == "paused")
    }

    @Test
    func aResumeAfterAFailedOneCanSucceed() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        fixture.recordingService.resumeResult = false
        try #require(await fixture.send("POST", "/v1/recordings/resume").status == 500)
        fixture.recordingService.resumeResult = true

        let response = await fixture.send("POST", "/v1/recordings/resume")

        #expect(response.status == 200)
        #expect(try decode(TransitionBody.self, response).session == started)
        #expect(try await state(fixture) == "recording")
    }

    @Test
    func stopWhilePausedSavesTheSession() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)

        let response = await fixture.send("POST", "/v1/recordings/stop")

        #expect(response.status == 200)
        #expect(try decode(TransitionBody.self, response).session.id == started.id)
        #expect(fixture.coordinator.phase == .idle)
        #expect(try fixture.persistedSessions().count == 1)
        #expect(try await state(fixture) == "idle")
    }

    @Test(arguments: ["/v1/recordings", "/v1/recordings/quick-start"])
    func aStartWhilePausedIsRefused(target: String) async throws {
        let fixture = try await makeFixture()
        try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)

        let response = await fixture.send("POST", target, json: "{}")

        #expect(response.status == 409)
        #expect(errorCode(response) == "already_recording")
        #expect(fixture.coordinator.phase == .paused)
        #expect(try fixture.persistedSessions().count == 1)
    }

    @Test
    func renameAndTagThroughTheAPIWhilePausedAppearInTheStatus() async throws {
        let fixture = try await makeFixture()
        let ops = try fixture.tag("Ops")
        try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)

        let update = await fixture.send(
            "PATCH", "/v1/recordings/current",
            json: #"{"title": "Paused call", "tagIds": ["\#(ops.id.uuidString)"]}"#
        )

        #expect(update.status == 200)
        let status = try decode(StatusBody.self, await fixture.send("GET", "/v1/status"))
        #expect(status.state == "paused")
        #expect(status.session?.title == "Paused call")
        #expect(status.session?.tags.map(\.id) == [ops.id.uuidString])
    }

    // MARK: - Idle, starting, stopping

    @Test(arguments: transitionRoutes)
    func aTransitionWhileIdleIsRefused(target: String) async throws {
        let fixture = try await makeFixture()

        let response = await fixture.send("POST", target)

        #expect(response.status == 409)
        #expect(errorCode(response) == "not_recording")
        #expect(fixture.recordingService.pauseCallCount == 0)
        #expect(fixture.recordingService.resumeCallCount == 0)
    }

    @Test(arguments: transitionRoutes)
    func aTransitionWhileStartingIsRefused(target: String) async throws {
        let fixture = try await makeFixture()
        fixture.workspaceService.holdNextCall()
        let starting = Task { await fixture.send("POST", "/v1/recordings/quick-start") }
        await fixture.workspaceService.waitUntilHeld()

        let response = await fixture.send("POST", target)
        fixture.workspaceService.release()
        _ = await starting.value

        #expect(response.status == 409)
        #expect(errorCode(response) == "not_recording")
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.recordingService.pauseCallCount == 0)
    }

    @Test(arguments: transitionRoutes)
    func aTransitionWhileStoppingIsRefused(target: String) async throws {
        let transcriber = GatedStopLiveTranscriber()
        let fixture = try await makeFixture(transcriber: transcriber)
        try await start(fixture)
        await transcriber.waitUntilStarted()
        let stop = Task { await fixture.coordinator.stop(context: fixture.context)?.id }
        await transcriber.waitUntilStopping()

        let response = await fixture.send("POST", target)
        await transcriber.releaseStop()
        _ = await stop.value

        #expect(response.status == 409)
        #expect(errorCode(response) == "not_recording")
        #expect(fixture.recordingService.pauseCallCount == 0)
        #expect(fixture.recordingService.resumeCallCount == 0)
    }

    @Test(arguments: transitionRoutes)
    func aTransitionWhilePausedAndStoppingIsRefused(target: String) async throws {
        let transcriber = GatedStopLiveTranscriber()
        let fixture = try await makeFixture(transcriber: transcriber)
        try await start(fixture)
        await transcriber.waitUntilStarted()
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        let stop = Task { await fixture.coordinator.stop(context: fixture.context)?.id }
        await transcriber.waitUntilStopping()

        let response = await fixture.send("POST", target)
        let status = try await state(fixture)
        await transcriber.releaseStop()
        _ = await stop.value

        #expect(status == "stopping")
        #expect(response.status == 409)
        #expect(errorCode(response) == "not_recording")
        #expect(fixture.recordingService.resumeCallCount == 0)
    }

    // MARK: - Waiting for the first microphone audio

    @Test
    func statusWhileAPauseWaitsForMicrophoneAudioReportsRecording() async throws {
        let fixture = try await makeFixture()
        holdFirstMicAudio(fixture)
        try await start(fixture)
        let pause = Task { await fixture.send("POST", "/v1/recordings/pause") }
        await waitUntil { fixture.recordingService.frameCountCallCount > 0 }

        let status = try await state(fixture)
        fixture.recordingService.frameCountQueue = [(mic: 512, app: nil)]
        let paused = await pause.value

        #expect(status == "recording")
        #expect(paused.status == 200)
        #expect(try await state(fixture) == "paused")
    }

    @Test
    func aPauseWhileAnotherWaitsForMicrophoneAudioJoinsIt() async throws {
        let fixture = try await makeFixture()
        holdFirstMicAudio(fixture)
        let started = try await start(fixture)
        let first = Task { await fixture.send("POST", "/v1/recordings/pause") }
        await waitUntil { fixture.recordingService.frameCountCallCount > 0 }
        let second = Task { await fixture.send("POST", "/v1/recordings/pause") }
        await letRequestsArrive()

        fixture.recordingService.frameCountQueue = [(mic: 512, app: nil)]
        let responses = [await first.value, await second.value]

        #expect(responses.map(\.status) == [200, 200])
        #expect(try responses.map { try decode(TransitionBody.self, $0).session } == [started, started])
        #expect(fixture.recordingService.pauseCallCount == 1)
    }

    @Test
    func aResumeWhileAPauseWaitsForMicrophoneAudioKeepsRecording() async throws {
        let fixture = try await makeFixture()
        holdFirstMicAudio(fixture)
        let started = try await start(fixture)
        let pause = Task { await fixture.send("POST", "/v1/recordings/pause") }
        await waitUntil { fixture.recordingService.frameCountCallCount > 0 }

        let resume = await fixture.send("POST", "/v1/recordings/resume")
        let paused = await pause.value

        #expect(paused.status == 409)
        #expect(errorCode(paused) == "not_recording")
        #expect(resume.status == 200)
        #expect(try decode(TransitionBody.self, resume).session == started)
        #expect(fixture.coordinator.phase == .recording)
        #expect(fixture.recordingService.pauseCallCount == 0)
        #expect(try await state(fixture) == "recording")
    }

    @Test
    func aStopWhileAPauseWaitsForMicrophoneAudioStopsAndRefusesThePause() async throws {
        let fixture = try await makeFixture()
        holdFirstMicAudio(fixture)
        let started = try await start(fixture)
        let pause = Task { await fixture.send("POST", "/v1/recordings/pause") }
        await waitUntil { fixture.recordingService.frameCountCallCount > 0 }

        let stop = await fixture.send("POST", "/v1/recordings/stop")
        let paused = await pause.value

        #expect(paused.status == 409)
        #expect(errorCode(paused) == "not_recording")
        #expect(stop.status == 200)
        #expect(try decode(TransitionBody.self, stop).session.id == started.id)
        #expect(fixture.recordingService.pauseCallCount == 0)
        #expect(try await state(fixture) == "idle")
    }

    // MARK: - Resuming

    @Test
    func statusWhileResumingReportsPaused() async throws {
        let fixture = try await makeFixture()
        try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let resume = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await gate.waitUntilHolding()

        let status = try await state(fixture)
        await gate.open()
        let resumed = await resume.value

        #expect(status == "paused")
        #expect(resumed.status == 200)
        #expect(try await state(fixture) == "recording")
    }

    @Test
    func aResumeWhileResumingJoinsIt() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let first = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await gate.waitUntilHolding()
        let second = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await letRequestsArrive()

        await gate.open()
        let responses = [await first.value, await second.value]

        #expect(responses.map(\.status) == [200, 200])
        #expect(try responses.map { try decode(TransitionBody.self, $0).session } == [started, started])
        #expect(fixture.recordingService.resumeCallCount == 1)
    }

    @Test
    func aResumeJoiningAFailedResumeGetsItsResult() async throws {
        let fixture = try await makeFixture()
        try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        fixture.recordingService.resumeResult = false
        let first = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await gate.waitUntilHolding()
        let second = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await letRequestsArrive()

        await gate.open()
        let responses = [await first.value, await second.value]

        #expect(responses.map(\.status) == [500, 500])
        #expect(responses.map(errorCode) == ["resume_failed", "resume_failed"])
        #expect(fixture.recordingService.resumeCallCount == 1)
        #expect(try await state(fixture) == "paused")
    }

    @Test
    func aPauseWhileResumingWaitsForTheResumeThenPauses() async throws {
        let fixture = try await makeFixture()
        try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let resume = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await gate.waitUntilHolding()
        let pause = Task { await fixture.send("POST", "/v1/recordings/pause") }
        await letRequestsArrive()

        await gate.open()
        let resumed = await resume.value
        let paused = await pause.value

        #expect(resumed.status == 200)
        #expect(paused.status == 200)
        #expect(fixture.recordingService.pauseCallCount == 2)
        #expect(try await state(fixture) == "paused")
    }

    @Test
    func aStopWhileResumingWaitsForTheResumeThenStops() async throws {
        let fixture = try await makeFixture()
        let started = try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let resume = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await gate.waitUntilHolding()
        let stop = Task { await fixture.send("POST", "/v1/recordings/stop") }
        await letRequestsArrive()

        await gate.open()
        let resumed = await resume.value
        let stopped = await stop.value

        #expect(resumed.status == 200)
        #expect(stopped.status == 200)
        #expect(try decode(TransitionBody.self, stopped).session.id == started.id)
        #expect(try await state(fixture) == "idle")
    }

    // MARK: - Revocation and routing

    @Test
    func aClientRevokedDuringAResumeGetsUnauthorized() async throws {
        let fixture = try await makeFixture()
        try await start(fixture)
        try #require(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        let gate = AsyncGate()
        fixture.recordingService.resumeGate = gate
        let resume = Task { await fixture.send("POST", "/v1/recordings/resume") }
        await gate.waitUntilHolding()

        fixture.api.store.revoke(fixture.signer.clientID)
        await gate.open()
        let response = await resume.value

        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
    }

    @Test(arguments: transitionRoutes)
    func aTransitionRouteAcceptsOnlyPost(target: String) async throws {
        let fixture = try await makeFixture()

        let response = await fixture.send("GET", target)

        #expect(response.status == 405)
        #expect(errorCode(response) == "invalid_request")
        #expect(response.headers.first { $0.name == "Allow" }?.value == "POST")
    }

    // MARK: - Transcript

    /// Speech heard during a pause is in no transcript the API answers for the session.
    @Test
    func transcriptResponsesHoldNothingFromAPause() async throws {
        let speech = try await LivePauseEndToEndTests.serviceWithSpeechAroundAPause()
        let fixture = try await makeFixture(transcriber: CapturedSpeechTranscriber(service: speech.service, events: speech.events))
        fixture.api.renderTranscript = { session in
            session.displayedTranscript.map { MarkdownRenderer().renderMarkdown(session: session, transcript: $0) }
        }
        let started = try await start(fixture)
        #expect(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        #expect(await fixture.send("POST", "/v1/recordings/resume").status == 200)
        #expect(await fixture.send("POST", "/v1/recordings/pause").status == 200)
        #expect(await fixture.send("POST", "/v1/recordings/stop").status == 200)

        let detail = await fixture.send("GET", "/v1/sessions/\(started.id)")
        let latest = await fixture.send("GET", "/v1/sessions/latest")

        for response in [detail, latest] {
            #expect(response.status == 200)
            let body = try decode(DetailBody.self, response)
            #expect(body.id == started.id)
            let transcript = try #require(body.transcript)
            #expect(transcript.contains("speech"))
            #expect(!transcript.contains("sentinel"))
        }
    }
}

/// Feeds a recording's live transcription with captured events when it starts, in place of the
/// mock recording service's audio, which has none.
actor CapturedSpeechTranscriber: LiveTranscribing {
    private let service: LiveTranscriptionService
    private let events: [LiveAudioChunk]

    init(service: LiveTranscriptionService, events: [LiveAudioChunk]) {
        self.service = service
        self.events = events
    }

    func prepare(workspace: Workspace, config: LiveTranscriptionPipelineSettings) async {}

    func start(
        workspace: Workspace,
        config: LiveTranscriptionPipelineSettings,
        resultContinuation: AsyncStream<TranscriptSegment>.Continuation
    ) async throws {
        await service.setResultContinuationForTesting(resultContinuation)
        let anchor = events.first?.hostTime
        for event in events {
            await service.process(event, anchor: anchor)
        }
    }

    func process(_ chunk: LiveAudioChunk, anchor: HostNanoseconds?) async {}

    func stop() async -> LiveSessionResult {
        await service.stop()
    }
}
