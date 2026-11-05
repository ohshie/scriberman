import CoreAudio
import CoreGraphics
import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// The recording routes, driven through signed requests to the handler with a real capture
/// coordinator over mock capture services and an in-memory store.
@MainActor
struct ExtensionAPIRecordingTests {
    // MARK: - Fixture

    @MainActor
    final class Fixture {
        let api = ExtensionAPIFixture()
        let workspaceService = GatedWorkspaceService()
        let recordingService = MockRecordingService()
        let audioDeviceService = MockAudioDeviceService()
        let appAudioService = MockAppAudioService()
        let screenCaptureService = MockScreenCaptureService()
        let permissionService = MockPermissionService()
        let menuBarSettings: MenuBarSettings
        let viewModel: NewSessionViewModel
        let coordinator: CaptureCoordinator
        let container: ModelContainer
        let context: ModelContext
        private let readiness: Readiness
        var modelsReady: Bool {
            get { readiness.modelsReady }
            set { readiness.modelsReady = newValue }
        }
        var discardedPendingSessions = 0
        /// Every session the routes asked the window to show.
        var requestedSessions: [AppState.SessionRequest] = []
        private let suiteName = "ExtensionAPIRecordingTests-\(UUID().uuidString)"
        private(set) var signer: ExtensionAPITestSigner!

        init(
            transcriber: any LiveTranscribing = IdleLiveTranscriber(),
            saveContext: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }
        ) throws {
            permissionService.micStatus = .granted
            permissionService.screenRecordingStatus = .granted
            let userDefaults = try #require(UserDefaults(suiteName: suiteName))
            let workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
            workspaceService.result = .success(workspace)

            container = try ModelContainer(
                for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, RecordingTag.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            context = ModelContext(container)
            recordingService.persistsSessionsIn = container
            recordingService.isRecordingOverride = true

            viewModel = NewSessionViewModel(
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
            menuBarSettings = MenuBarSettings(userDefaults: userDefaults)
            viewModel.menuBarSettings = menuBarSettings
            let readiness = Readiness()
            self.readiness = readiness
            coordinator = CaptureCoordinator(
                viewModel: viewModel,
                workspaceService: workspaceService,
                permissionService: permissionService,
                menuBarSettings: menuBarSettings,
                modelsReady: { readiness.modelsReady }
            )
            coordinator.discardPendingSession = { [unowned self] in discardedPendingSessions += 1 }

            api.handler.recording = ExtensionAPIRecording(
                coordinator: coordinator,
                audioDeviceService: audioDeviceService,
                appAudioService: appAudioService,
                screenCaptureService: screenCaptureService,
                permissionService: permissionService,
                menuBarSettings: menuBarSettings,
                context: context,
                requestSession: { [unowned self] in requestedSessions.append($0) },
                saveContext: saveContext
            )
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        func pair() async throws {
            signer = try await api.pair()
        }

        func send(_ method: String, _ target: String, json: String? = nil) async -> HTTPResponse {
            await api.sendSigned(signer, method, target, body: Data((json ?? "").utf8))
        }

        func tag(_ name: String, isDefault: Bool = false) throws -> RecordingTag {
            let tag = RecordingTag(name: name, colorHex: "336699", isDefault: isDefault)
            context.insert(tag)
            try context.save()
            return tag
        }

        /// Sessions as a fresh context sees them.
        func persistedSessions() throws -> [RecordingSession] {
            try ModelContext(container).fetch(FetchDescriptor<RecordingSession>())
        }
    }

    @MainActor
    final class Readiness {
        var modelsReady = true
    }

    // MARK: - Bodies

    struct TagBody: Decodable, Hashable {
        let id: String
        let name: String
    }

    struct SessionBody: Decodable, Equatable {
        let id: String
        let title: String
        let startedAt: String
        let tags: [TagBody]
    }

    struct CaptureBody: Decodable, Equatable {
        let microphoneUid: String?
        let appBundleId: String?
        let displayId: UInt32?
    }

    struct StatusBody: Decodable {
        let state: String
        let session: SessionBody?
        let capture: CaptureBody?
    }

    struct StartBody: Decodable {
        let session: SessionBody
        let capture: CaptureBody
    }

    struct StopBody: Decodable {
        let session: SessionBody
    }

    struct OptionsBody: Decodable {
        struct Microphone: Decodable, Equatable {
            let uid: String
            let name: String
        }

        struct App: Decodable, Equatable {
            let bundleId: String
            let name: String
        }

        struct Display: Decodable, Equatable {
            let id: UInt32
            let name: String
        }

        let microphones: [Microphone]
        let apps: [App]
        let displays: [Display]
        let tags: [TagBody]
        let lastUsedMicrophoneUid: String?
        let lastUsedAppBundleId: String?
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        try JSONDecoder().decode(type, from: response.body)
    }

    private func isISO8601(_ text: String) -> Bool {
        ISO8601DateFormatter().date(from: text) != nil
    }

    // MARK: - Status

    @Test
    func statusWhileIdleHasNoSession() async throws {
        let fixture = try Fixture()
        try await fixture.pair()

        let response = await fixture.send("GET", "/v1/status")

        #expect(response.status == 200)
        let body = try decode(StatusBody.self, response)
        #expect(body.state == "idle")
        #expect(body.session == nil)
        #expect(body.capture == nil)
    }

    @Test
    func statusWhileRecordingReportsTheCurrentSessionAndCapture() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let work = try fixture.tag("Work")
        let mic = AudioInputDevice(id: 4, uid: "mic-usb", name: "USB Mic")
        fixture.audioDeviceService.availableDevices = [mic]
        let start = await fixture.send(
            "POST", "/v1/recordings",
            json: #"{"title": "Standup", "microphoneUid": "mic-usb", "tagIds": ["\#(work.id.uuidString)"]}"#
        )
        let started = try decode(StartBody.self, start)

        let response = await fixture.send("GET", "/v1/status")

        #expect(response.status == 200)
        let body = try decode(StatusBody.self, response)
        #expect(body.state == "recording")
        #expect(body.session == started.session)
        #expect(body.session?.title == "Standup")
        #expect(body.session?.tags == [TagBody(id: work.id.uuidString, name: "Work")])
        #expect(body.capture == CaptureBody(microphoneUid: "mic-usb", appBundleId: nil, displayId: nil))
    }

    @Test
    func statusWhileStartingReportsStarting() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.workspaceService.holdNextCall()
        let start = Task { await fixture.send("POST", "/v1/recordings/quick-start") }
        await fixture.workspaceService.waitUntilHeld()

        let response = await fixture.send("GET", "/v1/status")
        fixture.workspaceService.release()
        _ = await start.value

        let body = try decode(StatusBody.self, response)
        #expect(body.state == "starting")
        #expect(body.session == nil)
    }

    @Test
    func statusWhileStoppingReportsStoppingWithTheSession() async throws {
        let transcriber = GatedStopLiveTranscriber()
        let fixture = try Fixture(transcriber: transcriber)
        try await fixture.pair()
        let started = try decode(StartBody.self, await fixture.send("POST", "/v1/recordings", json: #"{"title": "Call"}"#))
        await transcriber.waitUntilStarted()
        let stop = Task { await fixture.coordinator.stop(context: fixture.context)?.id }
        await transcriber.waitUntilStopping()

        let response = await fixture.send("GET", "/v1/status")
        await transcriber.releaseStop()
        _ = await stop.value

        let body = try decode(StatusBody.self, response)
        #expect(body.state == "stopping")
        #expect(body.session?.id == started.session.id)
    }

    // MARK: - Capture options

    @Test
    func captureOptionsListDevicesAppsDisplaysAssignableTagsAndLastUsed() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.audioDeviceService.availableDevices = [AudioInputDevice(id: 4, uid: "mic-usb", name: "USB Mic")]
        fixture.appAudioService.runningApps = [CapturedApp(bundleID: "com.example.call", name: "Call", pid: 40, icon: nil)]
        fixture.screenCaptureService.availableDisplays = [CaptureDisplay(displayID: 77, name: "Studio", width: 5120, height: 2880)]
        let work = try fixture.tag("Work")
        _ = try fixture.tag("Untagged", isDefault: true)
        fixture.menuBarSettings.lastUsedMicUID = "mic-usb"
        fixture.menuBarSettings.lastUsedAppBundleID = "com.example.call"

        let response = await fixture.send("GET", "/v1/capture-options")

        #expect(response.status == 200)
        let body = try decode(OptionsBody.self, response)
        #expect(body.microphones == [.init(uid: "mic-usb", name: "USB Mic")])
        #expect(body.apps == [.init(bundleId: "com.example.call", name: "Call")])
        #expect(body.displays == [.init(id: 77, name: "Studio")])
        #expect(body.tags == [TagBody(id: work.id.uuidString, name: "Work")])
        #expect(body.lastUsedMicrophoneUid == "mic-usb")
        #expect(body.lastUsedAppBundleId == "com.example.call")
        #expect(fixture.appAudioService.refreshCalls > 0)
    }

    @Test
    func captureOptionsWithNothingLastUsedReportNull() async throws {
        let fixture = try Fixture()
        try await fixture.pair()

        let body = try decode(OptionsBody.self, await fixture.send("GET", "/v1/capture-options"))

        #expect(body.lastUsedMicrophoneUid == nil)
        #expect(body.lastUsedAppBundleId == nil)
    }

    // MARK: - Quick start

    @Test
    func quickStartRecordsTheLastUsedMicrophoneAndAppAndShowsTheSession() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.audioDeviceService.availableDevices = [AudioInputDevice(id: 6, uid: "mic-last", name: "Last Mic")]
        fixture.appAudioService.runningApps = [CapturedApp(bundleID: "com.example.last", name: "Last App", pid: 60, icon: nil)]
        fixture.menuBarSettings.lastUsedMicUID = "mic-last"
        fixture.menuBarSettings.lastUsedAppBundleID = "com.example.last"

        let response = await fixture.send("POST", "/v1/recordings/quick-start")

        #expect(response.status == 200)
        let body = try decode(StartBody.self, response)
        let session = try #require(try fixture.persistedSessions().first)
        #expect(body.session.id == "recording:\(session.id.uuidString)")
        #expect(body.session.title == CaptureCoordinator.quickStartTitle)
        #expect(isISO8601(body.session.startedAt))
        #expect(body.capture == CaptureBody(microphoneUid: "mic-last", appBundleId: "com.example.last", displayId: nil))
        #expect(fixture.discardedPendingSessions == 1)
        #expect(fixture.requestedSessions == [.recording(session.id)])
    }

    // MARK: - Start with options

    @Test
    func startWithOptionsRecordsTheChoiceAndShowsTheSession() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.audioDeviceService.availableDevices = [AudioInputDevice(id: 4, uid: "mic-usb", name: "USB Mic")]
        fixture.appAudioService.runningApps = [CapturedApp(bundleID: "com.example.call", name: "Call", pid: 40, icon: nil)]
        fixture.screenCaptureService.availableDisplays = [CaptureDisplay(displayID: 77, name: "Studio", width: 5120, height: 2880)]
        let work = try fixture.tag("Work")
        let client = try fixture.tag("Client")

        let response = await fixture.send("POST", "/v1/recordings", json: """
            {"title": "Planning", "microphoneUid": "mic-usb", "appBundleId": "com.example.call",
             "screen": true, "displayId": 77, "tagIds": ["\(work.id.uuidString)", "\(client.id.uuidString)"]}
            """)

        #expect(response.status == 200)
        let body = try decode(StartBody.self, response)
        #expect(body.session.title == "Planning")
        #expect(Set(body.session.tags) == [TagBody(id: work.id.uuidString, name: "Work"), TagBody(id: client.id.uuidString, name: "Client")])
        #expect(body.capture == CaptureBody(microphoneUid: "mic-usb", appBundleId: "com.example.call", displayId: 77))
        let call = try #require(fixture.recordingService.startCalls.first)
        #expect(call.micDeviceID == 4)
        #expect(call.appProcessID == 40)
        #expect(call.captureDisplayID == 77)
        let session = try #require(try fixture.persistedSessions().first)
        #expect(body.session.id == "recording:\(session.id.uuidString)")
        #expect(session.title == "Planning")
        #expect(Set(session.tags.map(\.id)) == [work.id, client.id])
        #expect(fixture.requestedSessions == [.recording(session.id)])
    }

    @Test
    func startReportsMicrophoneOnlyWhenAppAudioFallsBack() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.audioDeviceService.availableDevices = [AudioInputDevice(id: 4, uid: "mic-usb", name: "USB Mic")]
        fixture.appAudioService.runningApps = [CapturedApp(bundleID: "com.example.call", name: "Call", pid: 40, icon: nil)]
        fixture.recordingService.startThrowSequence = [.failedToStart("tap")]

        let response = await fixture.send(
            "POST", "/v1/recordings",
            json: #"{"title": "Call", "microphoneUid": "mic-usb", "appBundleId": "com.example.call"}"#
        )

        #expect(response.status == 200)
        let body = try decode(StartBody.self, response)
        #expect(body.capture == CaptureBody(microphoneUid: "mic-usb", appBundleId: nil, displayId: nil))
    }

    @Test
    func startWithoutATitleUsesTheQuickStartTitle() async throws {
        let fixture = try Fixture()
        try await fixture.pair()

        let response = await fixture.send("POST", "/v1/recordings", json: "{}")

        #expect(response.status == 200)
        #expect(try decode(StartBody.self, response).session.title == CaptureCoordinator.quickStartTitle)
    }

    @Test(arguments: [
        "",
        "[]",
        #"{"microphoneUid": "mic-missing"}"#,
        #"{"appBundleId": "com.example.missing"}"#,
        #"{"screen": true}"#,
        #"{"screen": true, "displayId": 99}"#,
        #"{"tagIds": ["not-a-uuid"]}"#,
        #"{"title": 5}"#,
    ])
    func startWithAnInvalidBodyIsRefusedBeforeCapture(json: String) async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.audioDeviceService.availableDevices = [AudioInputDevice(id: 4, uid: "mic-usb", name: "USB Mic")]
        fixture.screenCaptureService.availableDisplays = [CaptureDisplay(displayID: 77, name: "Studio", width: 5120, height: 2880)]

        let response = await fixture.send("POST", "/v1/recordings", json: json)

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_request")
        #expect(fixture.recordingService.startCalls.isEmpty)
    }

    // MARK: - Tag choices

    @Test
    func anUnknownTagRefusesTheStartBeforeCapture() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let work = try fixture.tag("Work")

        let response = await fixture.send(
            "POST", "/v1/recordings",
            json: #"{"tagIds": ["\#(work.id.uuidString)", "\#(UUID().uuidString)"]}"#
        )

        #expect(response.status == 400)
        #expect(errorCode(response) == "unknown_tag")
        #expect(fixture.recordingService.startCalls.isEmpty)
        #expect(try fixture.persistedSessions().isEmpty)
        #expect(fixture.requestedSessions.isEmpty)
    }

    @Test
    func theDefaultTagRefusesTheStartBeforeCapture() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let untagged = try fixture.tag("Untagged", isDefault: true)

        let response = await fixture.send("POST", "/v1/recordings", json: #"{"tagIds": ["\#(untagged.id.uuidString)"]}"#)

        #expect(response.status == 400)
        #expect(errorCode(response) == "tag_not_assignable")
        #expect(fixture.recordingService.startCalls.isEmpty)
        #expect(try fixture.persistedSessions().isEmpty)
    }

    @Test
    func moreThanThreeTagsRefuseTheStartBeforeCapture() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let ids = try (1...4).map { try fixture.tag("Tag \($0)").id.uuidString }
        let list = ids.map { "\"\($0)\"" }.joined(separator: ", ")

        let response = await fixture.send("POST", "/v1/recordings", json: #"{"tagIds": [\#(list)]}"#)

        #expect(response.status == 400)
        #expect(errorCode(response) == "too_many_tags")
        #expect(fixture.recordingService.startCalls.isEmpty)
        #expect(try fixture.persistedSessions().isEmpty)
    }

    @Test
    func aRepeatedTagCountsOnce() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let tags = try (1...3).map { try fixture.tag("Tag \($0)").id.uuidString }
        let list = (tags + [tags[0]]).map { "\"\($0)\"" }.joined(separator: ", ")

        let response = await fixture.send("POST", "/v1/recordings", json: #"{"tagIds": [\#(list)]}"#)

        #expect(response.status == 200)
        #expect(try decode(StartBody.self, response).session.tags.count == 3)
    }

    // MARK: - Refusals

    @Test
    func aStartWhileRecordingIsRefused() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        _ = await fixture.send("POST", "/v1/recordings/quick-start")

        let quick = await fixture.send("POST", "/v1/recordings/quick-start")
        let withOptions = await fixture.send("POST", "/v1/recordings", json: #"{"title": "Second"}"#)

        #expect(quick.status == 409)
        #expect(errorCode(quick) == "already_recording")
        #expect(withOptions.status == 409)
        #expect(errorCode(withOptions) == "already_recording")
        #expect(fixture.recordingService.startCalls.count == 1)
    }

    @Test
    func aStartIsRefusedWhenModelsAreMissing() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.modelsReady = false

        let quick = await fixture.send("POST", "/v1/recordings/quick-start")
        let withOptions = await fixture.send("POST", "/v1/recordings", json: "{}")

        #expect(quick.status == 409)
        #expect(errorCode(quick) == "models_missing")
        #expect(errorCode(withOptions) == "models_missing")
        #expect(fixture.recordingService.startCalls.isEmpty)
    }

    @Test
    func aStartIsRefusedWithoutAWorkspace() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.workspaceService.result = .failure(.notConfigured)

        let response = await fixture.send("POST", "/v1/recordings", json: "{}")

        #expect(response.status == 409)
        #expect(errorCode(response) == "workspace_unavailable")
        #expect(fixture.recordingService.startCalls.isEmpty)
    }

    @Test
    func aStartIsRefusedWithoutMicrophonePermission() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.permissionService.micStatus = .denied

        let response = await fixture.send("POST", "/v1/recordings/quick-start")

        #expect(response.status == 409)
        #expect(errorCode(response) == "permission_missing")
        #expect(fixture.recordingService.startCalls.isEmpty)
    }

    // MARK: - Stop

    @Test
    func stopReturnsTheSessionAndShowsIt() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let started = try decode(StartBody.self, await fixture.send("POST", "/v1/recordings", json: #"{"title": "Call"}"#))
        fixture.requestedSessions = []

        let response = await fixture.send("POST", "/v1/recordings/stop")

        #expect(response.status == 200)
        let body = try decode(StopBody.self, response)
        #expect(body.session.id == started.session.id)
        #expect(body.session.title == "Call")
        #expect(fixture.coordinator.phase == .idle)
        let session = try #require(try fixture.persistedSessions().first)
        #expect(fixture.requestedSessions == [.recording(session.id)])
    }

    @Test
    func stopWhileIdleIsRefused() async throws {
        let fixture = try Fixture()
        try await fixture.pair()

        let response = await fixture.send("POST", "/v1/recordings/stop")

        #expect(response.status == 409)
        #expect(errorCode(response) == "not_recording")
        #expect(fixture.requestedSessions.isEmpty)
    }

    @Test
    func stopJoinsAStopUnderWay() async throws {
        let transcriber = GatedStopLiveTranscriber()
        let fixture = try Fixture(transcriber: transcriber)
        try await fixture.pair()
        let started = try decode(StartBody.self, await fixture.send("POST", "/v1/recordings", json: #"{"title": "Call"}"#))
        await transcriber.waitUntilStarted()
        let windowStop = Task { await fixture.coordinator.stop(context: fixture.context)?.id }
        await transcriber.waitUntilStopping()

        let apiStop = Task { await fixture.send("POST", "/v1/recordings/stop") }
        await Task.yield()
        await transcriber.releaseStop()
        let response = await apiStop.value

        #expect(response.status == 200)
        #expect(try decode(StopBody.self, response).session.id == started.session.id)
        #expect(await windowStop.value.map { "recording:\($0.uuidString)" } == started.session.id)
        #expect(try fixture.persistedSessions().count == 1)
    }

    // MARK: - Revocation

    @Test
    func aClientRevokedDuringAStartGetsUnauthorized() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        fixture.workspaceService.holdNextCall()
        let start = Task { await fixture.send("POST", "/v1/recordings/quick-start") }
        await fixture.workspaceService.waitUntilHeld()

        fixture.api.store.revoke(fixture.signer.clientID)
        fixture.workspaceService.release()
        let response = await start.value

        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
    }

    // MARK: - Rename and tag the current recording

    struct UpdateBody: Decodable {
        let session: SessionBody
    }

    private struct SaveFailure: Error {}

    /// Starts a recording with `title` and `tags` and returns the session the start reported.
    private func startRecording(
        _ fixture: Fixture,
        title: String = "Standup",
        tags: [RecordingTag] = []
    ) async throws -> SessionBody {
        let list = tags.map { "\"\($0.id.uuidString)\"" }.joined(separator: ", ")
        let response = await fixture.send("POST", "/v1/recordings", json: #"{"title": "\#(title)", "tagIds": [\#(list)]}"#)
        try #require(response.status == 200)
        return try decode(StartBody.self, response).session
    }

    /// The session with the API id `id`, as a fresh context sees it.
    private func persisted(_ fixture: Fixture, _ id: String) throws -> RecordingSession? {
        try fixture.persistedSessions().first { "recording:\($0.id.uuidString)" == id }
    }

    /// Ids of the tags a stored session carries, the default tag included.
    private func tagIDs(_ session: RecordingSession?) -> Set<UUID> {
        Set(session?.tags.map(\.id) ?? [])
    }

    /// Admits a signed PATCH of the current recording and returns a closure that sends its body,
    /// so a test can act between the head and the body.
    private func admitUpdate(_ fixture: Fixture, json: String) async throws -> () async -> HTTPResponse {
        let body = Data(json.utf8)
        let target = "/v1/recordings/current"
        let headers = fixture.signer.headers(method: "PATCH", target: target, body: body, timestamp: fixture.api.now)
        let head = fixture.api.head("PATCH", target, headers: headers, contentLength: body.count)
        let admission = await fixture.api.handler.admit(head, peer: fixture.api.peer)
        guard case .admitted = admission else {
            Issue.record("PATCH was not admitted: \(admission)")
            throw SaveFailure()
        }
        let handler = fixture.api.handler
        let peer = fixture.api.peer
        return { await handler.handle(head, body: body, peer: peer) }
    }

    @Test
    func renameAloneSavesTheTitleAndKeepsTheTags() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let work = try fixture.tag("Work")
        let started = try await startRecording(fixture, tags: [work])

        let response = await fixture.send("PATCH", "/v1/recordings/current", json: #"{"title": "Planning"}"#)

        #expect(response.status == 200)
        let body = try decode(UpdateBody.self, response)
        #expect(body.session.id == started.id)
        #expect(body.session.title == "Planning")
        #expect(body.session.tags == [TagBody(id: work.id.uuidString, name: "Work")])
        let stored = try persisted(fixture, started.id)
        #expect(stored?.title == "Planning")
        #expect(tagIDs(stored) == [work.id])
    }

    @Test
    func tagAloneAddsTheTagInPlaceOfTheDefaultAndKeepsTheTitle() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        _ = try fixture.tag("Untagged", isDefault: true)
        let work = try fixture.tag("Work")
        let started = try await startRecording(fixture)

        let response = await fixture.send(
            "PATCH", "/v1/recordings/current", json: #"{"tagIds": ["\#(work.id.uuidString)"]}"#
        )

        #expect(response.status == 200)
        #expect(try decode(UpdateBody.self, response).session.tags == [TagBody(id: work.id.uuidString, name: "Work")])
        let stored = try persisted(fixture, started.id)
        #expect(stored?.title == "Standup")
        #expect(tagIDs(stored) == [work.id])
    }

    @Test
    func renameAndTagTogetherApplyBoth() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let work = try fixture.tag("Work")
        let ops = try fixture.tag("Ops")
        let started = try await startRecording(fixture, tags: [work])

        let response = await fixture.send(
            "PATCH", "/v1/recordings/current",
            json: #"{"title": "Incident review", "tagIds": ["\#(ops.id.uuidString)"]}"#
        )

        #expect(response.status == 200)
        let body = try decode(UpdateBody.self, response)
        #expect(body.session.title == "Incident review")
        #expect(Set(body.session.tags) == [
            TagBody(id: work.id.uuidString, name: "Work"),
            TagBody(id: ops.id.uuidString, name: "Ops"),
        ])
        let stored = try persisted(fixture, started.id)
        #expect(stored?.title == "Incident review")
        #expect(tagIDs(stored) == [work.id, ops.id])
    }

    @Test
    func statusShowsTheRenamedSession() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        _ = try await startRecording(fixture)

        _ = await fixture.send("PATCH", "/v1/recordings/current", json: #"{"title": "Planning"}"#)
        let status = try decode(StatusBody.self, await fixture.send("GET", "/v1/status"))

        #expect(status.session?.title == "Planning")
    }

    @Test
    func anAlreadyAssignedTagIsIgnored() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let tags = try (1...3).map { try fixture.tag("Tag \($0)") }
        let started = try await startRecording(fixture, tags: tags)

        let response = await fixture.send(
            "PATCH", "/v1/recordings/current",
            json: #"{"title": "Planning", "tagIds": ["\#(tags[0].id.uuidString)", "\#(tags[0].id.uuidString)"]}"#
        )

        #expect(response.status == 200)
        let stored = try persisted(fixture, started.id)
        #expect(stored?.title == "Planning")
        #expect(tagIDs(stored) == Set(tags.map(\.id)))
    }

    enum TagRefusal: String, CaseIterable, Sendable {
        case unknown = "unknown_tag"
        case notAssignable = "tag_not_assignable"
        case tooMany = "too_many_tags"
    }

    @Test(arguments: TagRefusal.allCases)
    func aRefusedTagLeavesTitleAndTagsUnchanged(refusal: TagRefusal) async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let untagged = try fixture.tag("Untagged", isDefault: true)
        let first = try fixture.tag("First")
        let second = try fixture.tag("Second")
        let third = try fixture.tag("Third")
        let fourth = try fixture.tag("Fourth")
        let started = try await startRecording(fixture, tags: [first, second])
        let requested: [String] = switch refusal {
        case .unknown: [third.id.uuidString, UUID().uuidString]
        case .notAssignable: [third.id.uuidString, untagged.id.uuidString]
        case .tooMany: [third.id.uuidString, fourth.id.uuidString]
        }
        let list = requested.map { "\"\($0)\"" }.joined(separator: ", ")

        let response = await fixture.send(
            "PATCH", "/v1/recordings/current", json: #"{"title": "Planning", "tagIds": [\#(list)]}"#
        )

        #expect(response.status == 400)
        #expect(errorCode(response) == refusal.rawValue)
        let stored = try persisted(fixture, started.id)
        #expect(stored?.title == "Standup")
        #expect(tagIDs(stored) == [first.id, second.id])
        let status = try decode(StatusBody.self, await fixture.send("GET", "/v1/status"))
        #expect(status.session == started)
    }

    @Test(arguments: [
        "",
        "not json",
        "{}",
        #"{"title": "   "}"#,
        #"{"title": 4}"#,
        #"{"tagIds": ["not-a-uuid"]}"#,
    ])
    func anInvalidUpdateIsRefused(json: String) async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let started = try await startRecording(fixture)

        let response = await fixture.send("PATCH", "/v1/recordings/current", json: json)

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_request")
        #expect(try persisted(fixture, started.id)?.title == "Standup")
    }

    @Test
    func anUpdateWhileIdleIsRefused() async throws {
        let fixture = try Fixture()
        try await fixture.pair()

        let response = await fixture.send("PATCH", "/v1/recordings/current", json: #"{"title": "Planning"}"#)

        #expect(response.status == 409)
        #expect(errorCode(response) == "not_recording")
    }

    @Test
    func anUpdateWhileStoppingIsRefused() async throws {
        let transcriber = GatedStopLiveTranscriber()
        let fixture = try Fixture(transcriber: transcriber)
        try await fixture.pair()
        let started = try await startRecording(fixture)
        await transcriber.waitUntilStarted()
        let stop = Task { await fixture.coordinator.stop(context: fixture.context)?.id }
        await transcriber.waitUntilStopping()

        let response = await fixture.send("PATCH", "/v1/recordings/current", json: #"{"title": "Planning"}"#)
        await transcriber.releaseStop()
        _ = await stop.value

        #expect(response.status == 409)
        #expect(errorCode(response) == "not_recording")
        #expect(try persisted(fixture, started.id)?.title == "Standup")
    }

    @Test
    func aSessionDeletedDuringTheRequestIsNotFoundAndNothingIsWritten() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let work = try fixture.tag("Work")
        let started = try await startRecording(fixture)
        let send = try await admitUpdate(fixture, json: #"{"title": "Planning", "tagIds": ["\#(work.id.uuidString)"]}"#)

        let session = try #require(fixture.context.fetch(FetchDescriptor<RecordingSession>()).first)
        fixture.context.delete(session)
        try fixture.context.save()
        let response = await send()

        #expect(response.status == 404)
        #expect(errorCode(response) == "not_found")
        #expect(try persisted(fixture, started.id) == nil)
        #expect(try fixture.persistedSessions().isEmpty)
    }

    @Test
    func aClientRevokedDuringTheRequestGetsUnauthorizedAndNothingIsWritten() async throws {
        let fixture = try Fixture()
        try await fixture.pair()
        let work = try fixture.tag("Work")
        let started = try await startRecording(fixture)
        let before = tagIDs(try persisted(fixture, started.id))
        let send = try await admitUpdate(fixture, json: #"{"title": "Planning", "tagIds": ["\#(work.id.uuidString)"]}"#)

        fixture.api.store.revoke(fixture.signer.clientID)
        let response = await send()

        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
        let stored = try persisted(fixture, started.id)
        #expect(stored?.title == "Standup")
        #expect(tagIDs(stored) == before)
    }

    @Test
    func aFailedSaveRollsBackTitleAndTags() async throws {
        var failSaves = false
        let fixture = try Fixture(saveContext: { context in
            if failSaves { throw SaveFailure() }
            try context.save()
        })
        try await fixture.pair()
        let work = try fixture.tag("Work")
        let started = try await startRecording(fixture)
        let before = tagIDs(try persisted(fixture, started.id))
        failSaves = true

        let response = await fixture.send(
            "PATCH", "/v1/recordings/current",
            json: #"{"title": "Planning", "tagIds": ["\#(work.id.uuidString)"]}"#
        )

        #expect(response.status == 500)
        #expect(errorCode(response) == "save_failed")
        let stored = try persisted(fixture, started.id)
        #expect(stored?.title == "Standup")
        #expect(tagIDs(stored) == before)
        let status = try decode(StatusBody.self, await fixture.send("GET", "/v1/status"))
        #expect(status.session == started)
    }
}

/// A workspace service whose next call can be held open, so a test can act while a start is
/// under way.
final class GatedWorkspaceService: WorkspaceServiceProtocol, @unchecked Sendable {
    var result: Result<Workspace, WorkspaceError> = .failure(.notConfigured)
    private var holdNext = false
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    @MainActor
    func holdNextCall() {
        holdNext = true
    }

    @MainActor
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    @MainActor
    func release() {
        held?.resume()
        held = nil
    }

    func currentWorkspace() async -> Workspace? {
        try? result.get()
    }

    @MainActor
    func requireAuthorizedWorkspace() async throws(WorkspaceError) -> Workspace {
        if holdNext {
            holdNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
        return try result.get()
    }
}
