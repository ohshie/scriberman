import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Scriberman

final class RecordingServiceTests {
    private func fetchRecordingSession(id: UUID, from context: ModelContext) throws -> RecordingSession {
        var descriptor = FetchDescriptor<RecordingSession>()
        descriptor.fetchLimit = 1_000
        return try #require(context.fetch(descriptor).first(where: { $0.id == id }))
    }

    @Test

    func testSessionRecordingFileURLsUseNamedFolderAndNotTmp() {
        let workspace = makeWorkspace()
        let createdAt = Date(timeIntervalSince1970: 1_743_171_000) // 2025-03-28 14:30 UTC
        let identifier = "12345678-a3"
        let urls = RecordingService.recordingFileURLs(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: identifier
        )
        let folderName = RecordingService.folderName(createdAt: createdAt, recordingIdentifier: identifier)

        #expect(urls.mic.path.hasSuffix("/recordings/\(folderName)/mic.wav"))
        #expect(urls.app.path.hasSuffix("/recordings/\(folderName)/app.wav"))
        #expect(!urls.mic.path.contains("/recordings/tmp/"))
        #expect(!urls.app.path.contains("/recordings/tmp/"))
    }

    @Test

    func testRecordingFolderURLUsesExistingNamedPattern() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000) // 2025-03-28 14:30 UTC
        let folderURL = RecordingService.recordingFolderURL(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "12345678-a3"
        )
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let folderName = folderURL.lastPathComponent
        let expectedPattern = #"^Recording [A-Z][a-z]{2} \d{2} at \d{2}-\d{2} [A-Za-z0-9]{2}$"#

        #expect(FileManager.default.fileExists(atPath: folderURL.path))
        #expect(folderName.range(of: expectedPattern, options: .regularExpression) != nil)
    }

    @Test

    func testSessionRecordingFolderPathUsesNamedFolderNotTmp() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000)
        let result = RecordingService.recordingFileURLs(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "abcdef12"
        )
        let folderName = RecordingService.folderName(createdAt: createdAt, recordingIdentifier: "abcdef12")

        #expect(result.mic.path.hasSuffix("/recordings/\(folderName)/mic.wav"))
        #expect(!(result.mic.path.contains("/recordings/tmp/")))
    }

    @Test

    func testFolderBasedPathExpectationUsesNamedFolderMicFile() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000)
        let result = RecordingService.recordingFileURLs(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "11111111-a3"
        )
        let folderName = RecordingService.folderName(createdAt: createdAt, recordingIdentifier: "11111111-a3")

        #expect(result.mic.path == workspace.recordingsURL.appendingPathComponent("\(folderName)/mic.wav").path)
        #expect(result.app.path == workspace.recordingsURL.appendingPathComponent("\(folderName)/app.wav").path)
    }

    @Test

    func testMixdownFailureLeavesSessionMixdownURLNilAndStatusUnchanged() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings
        )

        let context = ModelContext(container)
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            micAudioURL: "/tmp/missing-mic.wav",
            mixdownURL: nil,
            title: "Session",
            status: .recorded
        )
        context.insert(session)
        try context.save()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("recording.m4a")
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        await service.runMixdown(
            sessionID: session.id,
            micURL: URL(fileURLWithPath: "/tmp/does-not-exist-mic.wav"),
            appURL: nil,
            mixdownURL: outputURL,
            micStartHostTime: 1,
            appStartHostTime: nil
        )

        let sessionID = session.id
        let persisted = try fetchRecordingSession(id: sessionID, from: context)
        #expect(persisted.mixdownURL == nil)
        #expect(persisted.status == .recorded)
    }

    @Test

    func testStopRecordingWhenNotRecordingReturnsNil() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings
        )

        let result = await service.stopRecording()
        #expect(result == nil)
    }

    @Test

    func testCaptureHostTimesKeepsFirstObservedValues() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings
        )

        await service.captureMicStartHostTimeIfNeeded(1_000)
        await service.captureMicStartHostTimeIfNeeded(2_000)
        await service.captureAppStartHostTimeIfNeeded(3_000)
        await service.captureAppStartHostTimeIfNeeded(4_000)

        let hostTimes = await service.capturedHostTimes()
        #expect(hostTimes.mic == 1_000)
        #expect(hostTimes.app == 3_000)
    }

    @Test

    func testStartRecordingWithCustomTitlePersistsTitle() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)

        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings
        )

        let customTitle = "My Custom Title"
        let recordingCreatedAt = Date(timeIntervalSince1970: 1_743_171_000)
        let recordingIdentifier = "test-id"
        let sessionURLs = RecordingService.recordingFileURLs(
            in: workspace,
            createdAt: recordingCreatedAt,
            recordingIdentifier: recordingIdentifier
        )
        try FileManager.default.createDirectory(
            at: sessionURLs.mic.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: sessionURLs.mic.path, contents: Data("mic".utf8))
        let seededSession = RecordingSession(
            createdAt: recordingCreatedAt,
            duration: 0,
            micAudioURL: sessionURLs.mic.path,
            title: customTitle,
            status: .recording
        )
        let seedContext = ModelContext(container)
        seedContext.insert(seededSession)
        try seedContext.save()

        // Fake the recording state
        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: recordingIdentifier,
            recordingWorkspaceRootURL: workspace.rootURL,
            recordingCreatedAt: recordingCreatedAt,
            pendingTitle: customTitle,
            currentSessionID: seededSession.id
        )

        let sessionID = await service.stopRecording()
        #expect(sessionID != nil)
        let ctx = ModelContext(container)
        let fetched = try fetchRecordingSession(id: try #require(sessionID), from: ctx)
        #expect(fetched.title == customTitle)
    }

    @Test

    func testStopRecordingFallbacksToDefaultTitleWhenNoPendingTitle() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings
        )

        let recordingCreatedAt = Date(timeIntervalSince1970: 1_743_171_000)
        let recordingIdentifier = "test-id-default"
        let sessionURLs = RecordingService.recordingFileURLs(
            in: workspace,
            createdAt: recordingCreatedAt,
            recordingIdentifier: recordingIdentifier
        )
        try FileManager.default.createDirectory(
            at: sessionURLs.mic.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: sessionURLs.mic.path, contents: Data("mic".utf8))
        let seededSession = RecordingSession(
            createdAt: recordingCreatedAt,
            duration: 0,
            micAudioURL: sessionURLs.mic.path,
            title: "Recording Seed",
            status: .recording
        )
        let seedContext = ModelContext(container)
        seedContext.insert(seededSession)
        try seedContext.save()

        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: recordingIdentifier,
            recordingWorkspaceRootURL: workspace.rootURL,
            recordingCreatedAt: recordingCreatedAt,
            pendingTitle: nil,
            currentSessionID: seededSession.id
        )

        let sessionID = await service.stopRecording()
        #expect(sessionID != nil)
        let ctx = ModelContext(container)
        let fetched = try fetchRecordingSession(id: try #require(sessionID), from: ctx)
        #expect(fetched.title.hasPrefix("Recording "))
    }

    @Test @MainActor
    func testVoiceProcessingSetterCalledWhenEnabled() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suiteName = "RecordingServiceTests.vp.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName) ?? .standard
        ud.removePersistentDomain(forName: suiteName)
        defer { ud.removePersistentDomain(forName: suiteName) }

        let appAudioSettings = AppAudioSettings(userDefaults: ud)
        appAudioSettings.voiceProcessingEnabled = true

        let counter = VPCallCounter()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            voiceProcessingPropertySetter: { @Sendable [counter] _ in counter.increment() }
        )

        let inputNode = unsafeBitCast(NSObject(), to: AVAudioInputNode.self)
        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: true)
        #expect(counter.callCount == 1)

        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: false)
        #expect(counter.callCount == 1) // not called again when disabled
    }

    @Test @MainActor
    func testVoiceProcessingSetterNotCalledWhenDisabled() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let appAudioSettings = AppAudioSettings()
        // voiceProcessingEnabled defaults to false

        let counter = VPCallCounter()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            voiceProcessingPropertySetter: { @Sendable [counter] _ in counter.increment() }
        )

        let inputNode = unsafeBitCast(NSObject(), to: AVAudioInputNode.self)
        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: false)
        #expect(counter.callCount == 0)
    }

    @Test @MainActor
    func testVoiceProcessingSetterErrorDoesNotInterruptFlow() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let appAudioSettings = AppAudioSettings()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            voiceProcessingPropertySetter: { @Sendable _ in
                throw NSError(domain: "test", code: -1, userInfo: nil) // simulate failure
            }
        )

        let inputNode = unsafeBitCast(NSObject(), to: AVAudioInputNode.self)
        // Should not throw or crash; failure is logged and recording continues
        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: true)
        // Reaching here means no crash/throw
    }

    @Test
    func testConfigChangeWhileRecordingRecoverySuccessKeepsRecordingAndNoPendingError() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testConfigChangeWhileRecordingRecoveryFailureKeepsRecordingAndSchedulesRetry() async throws {
        let fixture = try await makeRecoveryFixture()
        fixture.micController.startCaptureError = RecordingError.failedToStart("forced")
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.consumePendingError() == nil)
        let debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(debugState.hasRecoveryRetryTask)
    }

    @Test
    func testConfigChangeWhileRecorderFallbackIsNoOp() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL,
            recorderFallbackActive: true
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(await fixture.service.consumePendingError() == nil)
        #expect(fixture.micController.startCaptureCalls.isEmpty)
    }

    @Test
    func testReentrantConfigChangeDuringRecoveryIsIgnored() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL,
            isRecoveringMicCapture: true
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.isEmpty)
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testMicStartHostTimeNotOverwrittenOnRecovery() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL
        )
        await fixture.service.captureMicStartHostTimeIfNeeded(1_000)
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()
        await fixture.service.captureMicStartHostTimeIfNeeded(2_000)

        #expect(await fixture.service.capturedHostTimes().mic == 1_000)
    }

    @Test
    func testRecoveryResolvesDesiredUIDToMatchingDeviceID() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a"),
            (id: 22, uid: "uid-b")
        ]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-b",
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 22)
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testRecoveryUIDNotFoundFallsBackToDefaultDevice() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a")
        ]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-missing",
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == nil)
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testRetargetMicWhileNotRecordingIsNoOp() async throws {
        let fixture = try await makeRecoveryFixture()

        await fixture.service.setRecordingStateForTesting(isRecording: false)
        await fixture.service.retargetMic(desiredDeviceUID: "uid-b")

        #expect(fixture.micController.startCaptureCalls.isEmpty)
    }

    @Test
    func testRetargetMicWhileRecordingUpdatesDesiredUIDAndTriggersRecovery() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a"),
            (id: 22, uid: "uid-b")
        ]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-a",
            micFileURL: micURL
        )

        await fixture.service.retargetMic(desiredDeviceUID: "uid-b")

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 22)
        let debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(debugState.desiredMicDeviceUID == "uid-b")
    }

    @Test
    func testRetargetMicRecoveryFailureSchedulesRetryThatCanRecoverLater() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a"),
            (id: 22, uid: "uid-b")
        ]
        fixture.micController.startCaptureErrors = [RecordingError.failedToStart("forced once")]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-a",
            micFileURL: micURL
        )

        await fixture.service.retargetMic(desiredDeviceUID: "uid-b")
        var debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(debugState.hasRecoveryRetryTask)

        await fixture.service.performMicRecoveryRetryAttemptForTesting()

        debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(!debugState.hasRecoveryRetryTask)
        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 22)
    }

    private func makeWorkspace() -> Workspace {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return Workspace(rootURL: rootURL)
    }

    private func removeWorkspace(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeRecoveryFixture() async throws -> (
        service: RecordingService,
        workspace: Workspace,
        hardware: MockRecoveryAudioDeviceHardware,
        micController: MockMicCaptureController
    ) {
        let workspace = makeWorkspace()
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let modelContainer = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let hardware = MockRecoveryAudioDeviceHardware()
        let micController = MockMicCaptureController()
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: modelContainer,
            appAudioSettings: appAudioSettings,
            hardware: hardware,
            micCaptureController: micController
        )
        return (service, workspace, hardware, micController)
    }
}

// Thread-safe call counter for voice processing setter tests
private final class VPCallCounter: @unchecked Sendable {
    private(set) var callCount = 0
    func increment() { callCount += 1 }
}

private final class MockMicCaptureController: MicCaptureControlling, @unchecked Sendable {
    struct StartCall {
        let deviceID: AudioDeviceID?
        let targetSampleRate: Double
    }

    var startCaptureError: Error?
    var startCaptureErrors: [Error] = []
    private(set) var startCaptureCalls: [StartCall] = []
    private(set) var stopCaptureCallCount = 0
    var isRunning = false

    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        micFileURL _: URL,
        micStreamer _: AudioFileStreamer,
        voiceProcessingEnabled _: Bool,
        applyVoiceProcessing _: @Sendable (AVAudioInputNode, Bool) -> Void,
        onFirstHostTime _: @escaping @Sendable (UInt64) -> Void,
        onBuffer _: @escaping @Sendable ([Float], Double) -> Void
    ) throws {
        if !startCaptureErrors.isEmpty {
            throw startCaptureErrors.removeFirst()
        }
        if let startCaptureError {
            throw startCaptureError
        }
        startCaptureCalls.append(.init(deviceID: deviceID, targetSampleRate: targetFormat.sampleRate))
        isRunning = true
    }

    func stopCapture() {
        stopCaptureCallCount += 1
        isRunning = false
    }

    func retargetDevice(_: AudioDeviceID?) throws {}

    func isCaptureRunning() -> Bool {
        isRunning
    }
}

private final class MockRecoveryAudioDeviceHardware: AudioDeviceHardwareProviding, @unchecked Sendable {
    var devices: [(id: AudioDeviceID, uid: String)] = []

    func allDeviceIDs() throws -> [AudioDeviceID] {
        devices.map(\.id)
    }

    func hasInputStream(deviceID _: AudioDeviceID) -> Bool {
        true
    }

    func deviceUID(deviceID: AudioDeviceID) -> String? {
        devices.first(where: { $0.id == deviceID })?.uid
    }

    func deviceName(deviceID _: AudioDeviceID) -> String? {
        "Mock Device"
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        devices.first?.id
    }
}
