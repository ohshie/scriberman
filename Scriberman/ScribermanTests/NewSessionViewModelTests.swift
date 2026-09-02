import Foundation
import CoreAudio
import CoreGraphics
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct NewSessionViewModelTests {
    private typealias Fixture = (
        workspaceService: MockWorkspaceService,
        recordingService: MockRecordingService,
        audioDeviceService: MockAudioDeviceService,
        appAudioService: MockNewSessionAppAudioService,
        permissionService: MockPermissionService,
        menuBarSettings: MenuBarSettings,
        viewModel: NewSessionViewModel,
        context: ModelContext,
        cleanup: () -> Void
    )

    private func makeFixture(
        screenRecordingStatus: PermissionStatus = .notDetermined,
        initialSelectedApp: CapturedApp? = nil,
        availableDisplays: [CaptureDisplay] = [],
        selectedDisplayID: CGDirectDisplayID? = nil
    ) -> Fixture {
        let workspaceService = MockWorkspaceService()
        let recordingService = MockRecordingService()
        let audioDeviceService = MockAudioDeviceService()
        let appAudioService = MockNewSessionAppAudioService()
        let screenCaptureService = MockScreenCaptureService()
        screenCaptureService.availableDisplays = availableDisplays
        screenCaptureService.selectedDisplayID = selectedDisplayID
        let permissionService = MockPermissionService()
        permissionService.screenRecordingStatus = screenRecordingStatus
        appAudioService.selectedApp = initialSelectedApp
        let userDefaultsSuiteName = "NewSessionViewModelTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: userDefaultsSuiteName) ?? .standard
        let workspace = Workspace(rootURL: URL(fileURLWithPath: "/tmp/workspace"))
        workspaceService.requireWritableResult = .success(workspace)

        let modelContainer = try! ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(modelContainer)

        let viewModel = NewSessionViewModel(
            workspaceService: workspaceService,
            recordingService: recordingService,
            audioDeviceService: audioDeviceService,
            appAudioService: appAudioService,
            screenCaptureService: screenCaptureService,
            permissionService: permissionService,
            userDefaults: userDefaults
        )
        let menuBarSettings = MenuBarSettings(userDefaults: userDefaults)
        viewModel.menuBarSettings = menuBarSettings

        return (
            workspaceService,
            recordingService,
            audioDeviceService,
            appAudioService,
            permissionService,
            menuBarSettings,
            viewModel,
            context,
            { userDefaults.removePersistentDomain(forName: userDefaultsSuiteName) }
        )
    }

    @Test
    func testStateMachineTransitionsIdleToRecordingToStopped() async throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        recordingService.isRecordingOverride = false
        recordingService.audioLevelOverride = 0
        let stoppedSession = RecordingSession(
            createdAt: .now,
            duration: 3,
            micAudioURL: "/tmp/test.wav",
            title: "Recorded",
            status: .recorded
        )
        context.insert(stoppedSession)
        try context.save()
        recordingService.stopReturns = stoppedSession.id

        await viewModel.startRecording(title: "Session", context: context)
        guard case .recording = viewModel.state else {
            Issue.record("Expected recording state after start")
            return
        }

        let session = await viewModel.stopRecording(context: context)
        guard case .idle = viewModel.state else {
            Issue.record("Expected idle state after stop")
            return
        }
        #expect(session?.id == stoppedSession.id)
    }

    @Test
    func testStartRecordingIncrementsUsageForSelectedDevice() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.micStatus = .granted
        let selectedDevice = AudioInputDevice(id: 7, uid: "uid-7", name: "Desk Mic")
        audioDeviceService.availableDevices = [selectedDevice]
        audioDeviceService.selectedDevice = selectedDevice
        viewModel.selectedDevice = selectedDevice

        await viewModel.startRecording(title: "Session", context: context)

        #expect(audioDeviceService.incrementUsageCalls == ["uid-7"])
    }

    @Test
    func testMonitorPublishesSeparateMicAndAppLevels() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, audioDeviceService, appAudioService, menuBarSettings)

        permissionService.micStatus = .granted
        recordingService.isRecordingOverride = true
        recordingService.audioLevelsOverride = (mic: 0.3, app: 0.7)

        await viewModel.startRecording(title: "Session", context: context)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, viewModel.appAudioLevel != 0.7 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.micAudioLevel == 0.3)
        #expect(viewModel.appAudioLevel == 0.7)
        if case .recording(_, let level) = viewModel.state {
            #expect(level == 0.7)
        } else {
            Issue.record("Expected recording state, got \(viewModel.state)")
        }

        viewModel.reset()
        #expect(viewModel.micAudioLevel == 0)
        #expect(viewModel.appAudioLevel == 0)
    }

    @Test
    func testAppLevelStaysZeroWithoutAppCapture() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, audioDeviceService, appAudioService, menuBarSettings)

        permissionService.micStatus = .granted
        recordingService.isRecordingOverride = true
        recordingService.audioLevelsOverride = (mic: 0.5, app: 0)

        await viewModel.startRecording(title: "Session", context: context)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, viewModel.micAudioLevel != 0.5 {
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.micAudioLevel == 0.5)
        #expect(viewModel.appAudioLevel == 0)
        viewModel.reset()
    }

    @Test
    func testStartRecordingIncrementsUsageForSelectedApp() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]
        viewModel.selectApp(app)

        await viewModel.startRecording(title: "Session", context: context)

        #expect(appAudioService.incrementUsageCalls == ["com.apple.Music"])
    }

    @Test
    func testRestoredSelectionOnLaunchEnablesAppAudioForRecording() async {
        let restoredApp = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture(
            screenRecordingStatus: .granted,
            initialSelectedApp: restoredApp
        )
        defer { cleanup() }
        _ = (workspaceService, audioDeviceService, appAudioService, menuBarSettings)

        permissionService.micStatus = .granted

        #expect(viewModel.recordAppAudio)
        #expect(viewModel.selectedApp?.bundleID == "com.apple.Music")

        await viewModel.startRecording(title: "Session", context: context)

        #expect(recordingService.startCalls.count == 1)
        #expect(recordingService.startCalls.first?.capturedAppName == "Music")
        #expect(recordingService.startCalls.first?.appProcessID == 123)
    }

    @Test
    func testStartRecordingPersistsLastUsedMicAndAppSelections() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context)

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        let device = AudioInputDevice(id: 7, uid: "uid-7", name: "Desk Mic")
        audioDeviceService.availableDevices = [device]
        viewModel.selectedDevice = device

        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]
        viewModel.selectApp(app)

        await viewModel.startRecording(title: "Session", context: context)

        #expect(menuBarSettings.lastUsedMicUID == "uid-7")
        #expect(menuBarSettings.lastUsedAppBundleID == "com.apple.Music")
    }

    @Test
    func testStartRecordingClearsLastUsedAppWhenNoAppSelected() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, viewModel, context)

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        menuBarSettings.lastUsedAppBundleID = "com.apple.OldApp"

        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]
        viewModel.selectApp(app)
        viewModel.selectApp(nil)

        await viewModel.startRecording(title: "Session", context: context)

        #expect(menuBarSettings.lastUsedAppBundleID == nil)
    }

    @Test
    func testStartRecordingPassesTitleToService() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.micStatus = .granted
        let customTitle = "Meeting with Team"
        
        await viewModel.startRecording(title: customTitle, context: context)
        
        #expect(recordingService.startCalls.count == 1)
        #expect(recordingService.startCalls.first?.title == customTitle)
    }

    @Test
    func testStartRecordingPassesSelectedDisplayIDWhenScreenRecordingEnabled() async {
        let display = CaptureDisplay(displayID: 77, name: "Display 1", width: 1728, height: 1117)
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture(
            screenRecordingStatus: .granted,
            availableDisplays: [display],
            selectedDisplayID: display.displayID
        )
        defer { cleanup() }
        _ = (workspaceService, audioDeviceService, appAudioService, permissionService, menuBarSettings, context)

        permissionService.micStatus = .granted
        viewModel.recordScreen = true

        await viewModel.startRecording(title: "Screen Session", context: context)

        #expect(recordingService.startCalls.count == 1)
        #expect(recordingService.startCalls.first?.captureDisplayID == 77)
    }

    @Test
    func testResetReturnsIdleFromRecordingState() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.state = .recording(duration: 10, level: 0)

        viewModel.reset()

        guard case .idle = viewModel.state else {
            Issue.record("Expected idle state after reset")
            return
        }
    }

    @Test
    func testIsIdleIsTrueWhenStateIsIdle() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.state = .idle

        #expect(viewModel.isIdle)
    }

    @Test
    func testIsIdleIsFalseWhenRecording() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.state = .recording(duration: 1, level: 0.5)

        #expect(!(viewModel.isIdle))
    }

    @Test
    func testCanRecordRequiresGrantedMicrophonePermission() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.micStatus = .notDetermined
        #expect(!(viewModel.canRecord))

        permissionService.micStatus = .denied
        #expect(!(viewModel.canRecord))

        permissionService.micStatus = .granted
        #expect(viewModel.canRecord)
    }

    @Test
    func testCanRecordRequiresSelectedAppWhenAppAudioEnabled() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.micStatus = .granted
        permissionService.screenRecordingStatus = .granted
        viewModel.recordAppAudio = true
        viewModel.selectedApp = nil
        #expect(!(viewModel.canRecord))

        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        viewModel.selectedApp = app
        #expect(viewModel.canRecord)
    }

    @Test
    func testCanRecordRequiresSelectedDisplayWhenScreenRecordingEnabled() {
        let display = CaptureDisplay(displayID: 55, name: "Display 1", width: 1512, height: 982)
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture(
            screenRecordingStatus: .granted,
            availableDisplays: [display],
            selectedDisplayID: display.displayID
        )
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.micStatus = .granted
        viewModel.recordScreen = true
        #expect(viewModel.canRecord)

        viewModel.selectedDisplayID = nil
        #expect(!viewModel.canRecord)
    }

    @Test
    func testRecordAppAudioToggleRequestsScreenPermissionWhenNotGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.screenRecordingStatus = .notDetermined

        viewModel.recordAppAudio = true

        #expect(permissionService.requestScreenRecordingCalls == 1)
        #expect(!(viewModel.recordAppAudio))
    }

    @Test
    func testRecordScreenToggleRequestsScreenPermissionWhenNotGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.screenRecordingStatus = .notDetermined

        viewModel.recordScreen = true

        #expect(permissionService.requestScreenRecordingCalls == 1)
        #expect(!viewModel.recordScreen)
    }

    @Test
    func testSelectAppSetsSelectedAppAndEnablesAppAudioWhenPermissionGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.screenRecordingStatus = .granted
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]

        viewModel.selectApp(app)

        #expect(viewModel.selectedApp?.bundleID == "com.apple.Music")
        #expect(viewModel.recordAppAudio)
    }

    @Test
    func testSelectAppNilDisablesAppAudioAndClearsSelection() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.screenRecordingStatus = .granted
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)
        appAudioService.runningApps = [app]
        viewModel.selectApp(app)

        viewModel.selectApp(nil)

        #expect(!(viewModel.recordAppAudio))
        #expect(viewModel.selectedApp == nil)
    }

    @Test
    func testSelectAppRequestsPermissionWhenNotGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.screenRecordingStatus = .denied
        let app = CapturedApp(bundleID: "com.apple.Music", name: "Music", pid: 123, icon: nil)

        viewModel.selectApp(app)

        #expect(permissionService.requestScreenRecordingCalls == 1)
        #expect(!(viewModel.recordAppAudio))
        #expect(viewModel.selectedApp == nil)
    }

    @Test
    func testMicPermissionWarningTextTracksMicStatus() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.micStatus = .notDetermined
        #expect(viewModel.micPermissionWarningText == "Microphone access needed to record. Click to allow.")
        #expect(!viewModel.micPermissionDenied)

        permissionService.micStatus = .denied
        #expect(viewModel.micPermissionWarningText == "Microphone access is disabled. Click to open Privacy Settings.")
        #expect(viewModel.micPermissionDenied)

        permissionService.micStatus = .granted
        #expect(viewModel.micPermissionWarningText == nil)
        #expect(!viewModel.micPermissionDenied)
    }

    @Test
    func testScreenPermissionWarningTextTracksScreenStatus() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.screenRecordingStatus = .notDetermined
        #expect(viewModel.screenPermissionWarningText == "Screen Recording permission needed for app audio and screen capture. Click to allow.")
        #expect(!viewModel.screenPermissionDenied)

        permissionService.screenRecordingStatus = .denied
        #expect(viewModel.screenPermissionWarningText == "Screen Recording is disabled. Click to open Privacy Settings.")
        #expect(viewModel.screenPermissionDenied)

        permissionService.screenRecordingStatus = .granted
        #expect(viewModel.screenPermissionWarningText == nil)
        #expect(!viewModel.screenPermissionDenied)
    }

    @Test
    func testRequestMicrophonePermissionInvokesPermissionService() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.requestMicResult = true
        permissionService.micStatus = .notDetermined

        await viewModel.requestMicrophonePermission()

        #expect(permissionService.requestMicCalls == 1)
        #expect(viewModel.microphonePermissionGranted)
    }

    @Test
    func testRequestScreenRecordingPermissionInvokesPermissionService() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.requestScreenRecordingPermission()
        #expect(permissionService.requestScreenRecordingCalls == 1)
    }

    @Test
    func testSingleAvailableDisplayCanBeUsedWithoutPicker() {
        let display = CaptureDisplay(displayID: 19, name: "Display 1", width: 2560, height: 1440)
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture(
            screenRecordingStatus: .granted,
            availableDisplays: [display],
            selectedDisplayID: display.displayID
        )
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.recordScreen = true

        #expect(viewModel.selectedDisplayID == display.displayID)
        #expect(!viewModel.showDisplayPicker)
    }

    @Test
    func testMultipleDisplaysShowPickerWhenScreenRecordingEnabled() {
        let displays = [
            CaptureDisplay(displayID: 1, name: "Display 1", width: 2560, height: 1440),
            CaptureDisplay(displayID: 2, name: "Display 2", width: 1920, height: 1080)
        ]
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture(
            screenRecordingStatus: .granted,
            availableDisplays: displays,
            selectedDisplayID: displays[0].displayID
        )
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.recordScreen = true

        #expect(viewModel.showDisplayPicker)
    }

    @Test
    func testRecheckPermissionsInvokesCheckAndVerifyMethods() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        await viewModel.recheckPermissions()
        #expect(permissionService.checkAllCalls == 1)
        #expect(permissionService.verifyMicCalls == 1)
        #expect(permissionService.verifyScreenRecordingCalls == 1)
    }

    @Test
    func testRefreshAudioDevicesOnAppearCallsAudioDeviceServiceRefresh() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.refreshAudioDevicesOnAppear()
        #expect(audioDeviceService.refreshDevicesCalls == 1)
    }

    @Test
    func testRefreshAudioDevicesOnPanelExpandedCallsAudioDeviceServiceRefresh() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        viewModel.refreshAudioDevicesOnPanelExpanded()
        #expect(audioDeviceService.refreshDevicesCalls == 1)
    }

    @Test
    func testAppAudioToggleRemainsEnabledWhenScreenPermissionNotGranted() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        permissionService.screenRecordingStatus = .denied
        #expect(viewModel.appAudioToggleEnabled)
    }

    @Test
    func testAirPodsDisconnectScenarioUpdatesSelectedDeviceStateFromService() {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        let airPods = AudioInputDevice(id: 2, uid: "uid-airpods", name: "AirPods")
        let builtIn = AudioInputDevice(id: 1, uid: "uid-built-in", name: "Built-in Mic")
        audioDeviceService.availableDevices = [airPods, builtIn]
        audioDeviceService.selectedDevice = airPods
        #expect(viewModel.selectedDevice?.uid == "uid-airpods")

        // Simulate disconnect fallback emitted by AudioDeviceService.
        audioDeviceService.availableDevices = [builtIn]
        audioDeviceService.selectedDevice = builtIn
        #expect(viewModel.selectedDevice?.uid == "uid-built-in")

        // Simulate reconnect recovery emitted by AudioDeviceService.
        audioDeviceService.availableDevices = [airPods, builtIn]
        audioDeviceService.selectedDevice = airPods
        #expect(viewModel.selectedDevice?.uid == "uid-airpods")
    }

    @Test
    func testSelectedDeviceChangeWhileRecordingRetargetsRecordingService() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, audioDeviceService, appAudioService, permissionService, menuBarSettings, context)

        recordingService.isRecordingOverride = true
        let device = AudioInputDevice(id: 7, uid: "uid-7", name: "Desk Mic")

        viewModel.selectedDevice = device
        await waitForRetargetCalls(recordingService, expectedCount: 1)

        #expect(recordingService.retargetMicCalls == ["uid-7"])
    }

    @Test
    func testSelectedDeviceChangeWhileIdleDoesNotRetargetRecordingService() async {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, audioDeviceService, appAudioService, permissionService, menuBarSettings, context)

        recordingService.isRecordingOverride = false
        let device = AudioInputDevice(id: 7, uid: "uid-7", name: "Desk Mic")

        viewModel.selectedDevice = device
        await Task.yield()
        await Task.yield()

        #expect(recordingService.retargetMicCalls.isEmpty)
    }

    @Test
    func testNewSessionPanelShowsMicPermissionWarningIndicator() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        let source = try newSessionPanelSource()
        #expect(source.contains("if let warning = viewModel.micPermissionWarningText"))
        #expect(source.contains("exclamationmark.triangle.fill"))
        #expect(source.contains(".help(reason)"))
        #expect(source.contains("openPrivacySettings(pane: \"Privacy_Microphone\")"))
    }

    @Test
    func testNewSessionPanelPromptRequestsMicPermissionViaViewModel() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        let source = try newSessionPanelSource()
        #expect(source.contains("await viewModel.requestMicrophonePermission()"))
    }

    @Test
    func testNewSessionPanelRefreshesAudioDevicesOnAppear() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        let source = try newSessionPanelSource()
        #expect(source.contains("viewModel.refreshAudioDevicesOnAppear()"))
    }

    @Test
    func testNewSessionPanelHasNoPermissionBannerAndWarnsOnScreenRow() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        let source = try newSessionPanelSource()
        #expect(!source.contains("permissionStatusWarningText"))
        #expect(!source.contains("Re-check Permissions"))
        #expect(!source.contains("Grant Microphone Access"))
        #expect(source.contains("if let warning = viewModel.screenPermissionWarningText"))
        #expect(source.contains("openPrivacySettings(pane: \"Privacy_ScreenCapture\")"))
    }

    @Test
    func testNewSessionPanelShowsRecordScreenControls() throws {
        let source = try newSessionPanelSource()
        #expect(source.contains("Text(\"Record app audio\")"))
        #expect(source.contains("Text(\"Record screen\")"))
        #expect(source.contains("viewModel.showDisplayPicker"))
        #expect(source.contains("Select display"))
    }

    @Test
    func testRefreshAudioDevicesOnAppearPreparesLiveTranscriptionWithWorkspace() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        let source = try newSessionViewModelSource()
        #expect(source.contains("if let workspace = await workspaceService.currentWorkspace()"))
        #expect(source.contains("await liveTranscriptionService.prepare(workspace: workspace, config: pipelineConfig)"))
    }

    @Test
    func testInitializationFailureMessageDirectsUserToSettingsModels() throws {
        let (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context, cleanup) = makeFixture()
        defer { cleanup() }
        _ = (workspaceService, recordingService, audioDeviceService, appAudioService, permissionService, menuBarSettings, viewModel, context)

        let source = try newSessionViewModelSource()
        #expect(source.contains("catch LiveTranscriptionError.initializationFailed"))
        #expect(source.contains("Open Settings → Models to install ASR and Speaker Diarization models."))
    }

    @Test
    func testMenuBarStartRecordingOverloadIsPresent() throws {
        let source = try newSessionViewModelSource()
        #expect(source.contains("func startRecording("))
        #expect(source.contains("micDeviceUID: String?"))
        #expect(source.contains("app: CapturedApp?"))
    }

    private func newSessionPanelSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/NewSessionPanelView.swift")
    }

    private func newSessionViewModelSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../ViewModels/NewSessionViewModel.swift")
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent(relativePathFromTests)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func waitForRetargetCalls(
        _ recordingService: MockRecordingService,
        expectedCount: Int,
        timeoutNanoseconds: UInt64 = 5_000_000_000,
        pollNanoseconds: UInt64 = 10_000_000
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if recordingService.retargetMicCalls.count >= expectedCount {
                return
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
    }
    // MARK: - Start verification and retry

    /// Polls until `condition` holds, or gives up. The verification delay is compressed to
    /// milliseconds by the tests, so the only real cost here is the failure path's log write.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(20),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Settles the healthy path, where there is no observable end state to poll for: give the
    /// verification task room to run and then confirm it did nothing.
    @MainActor
    private func waitForVerificationPass(_ recordingService: MockRecordingService) async {
        await waitUntil { recordingService.frameCountCallCount >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test
    @MainActor
    func testHealthyStartIsNotRestarted() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.recordingService.frameCountQueue = [(mic: 512, app: nil)]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitForVerificationPass(fixture.recordingService)

        #expect(fixture.recordingService.restartAudioCaptureCallCount == 0)
        #expect(!fixture.viewModel.didFailToStartRecording)
    }

    @Test
    @MainActor
    func testDeadStartIsRestartedOnceAndRecovers() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        // Dead on the first check, writing after the restart.
        fixture.recordingService.frameCountQueue = [(mic: 0, app: nil), (mic: 512, app: nil)]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.recordingService.restartAudioCaptureCallCount >= 1 }
        await waitUntil { fixture.recordingService.frameCountCallCount >= 2 }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(fixture.recordingService.restartAudioCaptureCallCount == 1)
        #expect(!fixture.viewModel.didFailToStartRecording)
    }

    @Test
    @MainActor
    func testDeadStartThatStaysDeadFailsAfterExactlyOneRestart() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.recordingService.frameCountQueue = [(mic: 0, app: nil)]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.viewModel.didFailToStartRecording }

        // Restarted once, never twice.
        #expect(fixture.recordingService.restartAudioCaptureCallCount == 1)
        #expect(fixture.viewModel.didFailToStartRecording)
        if case .idle = fixture.viewModel.state {} else {
            Issue.record("expected the failed session to return to idle")
        }
    }

    /// A restart that will not start at all must not be retried again either.
    @Test
    @MainActor
    func testFailedRestartIsNotRetried() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.recordingService.frameCountQueue = [(mic: 0, app: nil)]
        fixture.recordingService.restartAudioCaptureResult = false

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.viewModel.didFailToStartRecording }

        #expect(fixture.recordingService.restartAudioCaptureCallCount == 1)
        #expect(fixture.viewModel.didFailToStartRecording)
    }

    /// The retry keeps the same session: no second session is persisted.
    @Test
    @MainActor
    func testRetryDoesNotPersistASecondSession() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.recordingService.frameCountQueue = [(mic: 0, app: nil), (mic: 512, app: nil)]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.recordingService.restartAudioCaptureCallCount >= 1 }
        await waitUntil { fixture.recordingService.frameCountCallCount >= 2 }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(fixture.recordingService.startCalls.count == 1)
        #expect(fixture.recordingService.restartAudioCaptureCallCount == 1)
    }

    // MARK: - Recording start failure panel

    @Test
    @MainActor
    func testDismissingStartFailureHidesPanelAndClearsFlag() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        var presentations: [Bool] = []
        fixture.viewModel.didFailToStartRecording = true
        fixture.viewModel.onRecordingStartFailurePresentationChanged = { presentations.append($0) }

        fixture.viewModel.dismissRecordingStartFailure()

        #expect(presentations == [false])
        #expect(!fixture.viewModel.didFailToStartRecording)
    }

    /// A reset must not leave a stale failure panel on screen.
    @Test
    @MainActor
    func testResetClearsAnOutstandingStartFailure() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        var presentations: [Bool] = []
        fixture.viewModel.didFailToStartRecording = true
        fixture.viewModel.onRecordingStartFailurePresentationChanged = { presentations.append($0) }

        fixture.viewModel.reset()

        #expect(presentations == [false])
        #expect(!fixture.viewModel.didFailToStartRecording)
    }

    @Test
    @MainActor
    func testDismissWithNoOutstandingFailureStillHidesThePanel() {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        var presentations: [Bool] = []
        fixture.viewModel.onRecordingStartFailurePresentationChanged = { presentations.append($0) }

        fixture.viewModel.dismissRecordingStartFailure()

        #expect(presentations == [false])
    }

    // MARK: - Capture health (observation only)

    /// Health is sampled repeatedly for the life of the recording, not once near the start.
    @Test
    @MainActor
    func testCaptureHealthIsEvaluatedRepeatedlyWhileRecording() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 3 }

        #expect(fixture.recordingService.captureHealthSnapshotCallCount >= 3)
    }

    /// Frames that keep advancing are never judged unhealthy, however long the recording runs.
    @Test
    @MainActor
    func testAdvancingCaptureIsNeverJudgedUnhealthy() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true
        fixture.viewModel.captureHealthConfiguration = CaptureHealthMonitor.Configuration(
            stallThreshold: 0.02,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
        fixture.recordingService.captureHealthSnapshotQueue = (1...40).map {
            CaptureHealthMonitor.Snapshot(micFrames: Int64($0) * 960, appFrames: nil)
        }

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 10 }

        #expect(fixture.viewModel.lastCaptureHealthEffect == .none)
        #expect(!fixture.viewModel.wasCaptureInterrupted)
    }

    /// Capture that stops mid-recording is detected — the case the start safety net cannot see,
    /// because it verifies once and never looks again.
    @Test
    @MainActor
    func testStalledCaptureIsDetectedMidRecording() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true
        fixture.viewModel.captureHealthConfiguration = CaptureHealthMonitor.Configuration(
            stallThreshold: 0.05,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
        // A single snapshot is returned for every call, so the frame count never advances.
        fixture.recordingService.captureHealthSnapshotQueue = [
            CaptureHealthMonitor.Snapshot(micFrames: 512, appFrames: nil)
        ]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.viewModel.lastCaptureHealthEffect == .restart }

        #expect(fixture.viewModel.lastCaptureHealthEffect == .restart)
    }

    /// Detection must not act yet. Recovery ships in a later step, behind a flag, so this stage can
    /// be validated against real recordings without anything tearing capture down.
    @Test
    @MainActor
    func testDetectionDoesNotActWhileObservationOnly() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true
        fixture.viewModel.captureHealthConfiguration = CaptureHealthMonitor.Configuration(
            stallThreshold: 0.05,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
        fixture.recordingService.captureHealthSnapshotQueue = [
            CaptureHealthMonitor.Snapshot(micFrames: 512, appFrames: nil)
        ]
        // Healthy at start, so any restart observed could only have come from capture health.
        fixture.recordingService.frameCountQueue = [(mic: 512, app: nil)]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.viewModel.lastCaptureHealthEffect == .restart }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(fixture.recordingService.restartAudioCaptureCallCount == 0)
        #expect(!fixture.viewModel.didFailToStartRecording)
        if case .recording = fixture.viewModel.state {} else {
            Issue.record("observation-only detection must leave the recording running")
        }
    }

    /// A stream error is direct evidence and does not wait out the stall threshold.
    @Test
    @MainActor
    func testReportedStreamFailureIsDetectedWithoutWaitingForAStall() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true
        fixture.viewModel.captureHealthConfiguration = CaptureHealthMonitor.Configuration(
            stallThreshold: 3_600,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
        // Frames keep advancing throughout; only the failure count says the stream died.
        fixture.recordingService.captureHealthSnapshotQueue = [
            CaptureHealthMonitor.Snapshot(micFrames: 960, appFrames: nil, streamFailureCount: 0),
            CaptureHealthMonitor.Snapshot(micFrames: 1_920, appFrames: nil, streamFailureCount: 1)
        ]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.viewModel.lastCaptureHealthEffect == .restart }

        #expect(fixture.viewModel.lastCaptureHealthEffect == .restart)
    }

    /// The injected threshold is honoured: a long one keeps a stalled source healthy.
    @Test
    @MainActor
    func testLongStallThresholdDefersJudgement() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true
        fixture.viewModel.captureHealthConfiguration = CaptureHealthMonitor.Configuration(
            stallThreshold: 3_600,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
        fixture.recordingService.captureHealthSnapshotQueue = [
            CaptureHealthMonitor.Snapshot(micFrames: 512, appFrames: nil)
        ]

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 10 }

        #expect(fixture.viewModel.lastCaptureHealthEffect == .none)
    }

    /// App audio stalling on its own must not be judged a dead capture: under unified capture,
    /// restarting for it would tear down a healthy microphone.
    @Test
    @MainActor
    func testAppOnlyStallIsNotTreatedAsDeadCapture() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true
        fixture.viewModel.captureHealthConfiguration = CaptureHealthMonitor.Configuration(
            stallThreshold: 0.05,
            consecutiveRestartLimit: 3,
            totalRestartLimit: 10
        )
        fixture.recordingService.captureHealthSnapshotQueue = (1...40).map {
            CaptureHealthMonitor.Snapshot(micFrames: Int64($0) * 960, appFrames: 960)
        }

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 12 }

        #expect(fixture.viewModel.lastCaptureHealthEffect == .none)
    }

    /// Stopping ends evaluation and clears the monitor, so the next recording starts from a clean
    /// baseline rather than mid-stall.
    @Test
    @MainActor
    func testStoppingEndsCaptureHealthEvaluation() async {
        let fixture = makeFixture()
        defer { fixture.cleanup() }
        fixture.viewModel.startVerificationDelay = .milliseconds(1)
        fixture.viewModel.captureHealthEvaluationInterval = 0.01
        // The recording monitor's loop exits unless the service reports it is recording.
        fixture.recordingService.isRecordingOverride = true

        _ = await fixture.viewModel.startRecording(title: "t", context: fixture.context)
        await waitUntil { fixture.recordingService.captureHealthSnapshotCallCount >= 2 }
        _ = await fixture.viewModel.stopRecording(context: fixture.context)

        let countAfterStop = fixture.recordingService.captureHealthSnapshotCallCount
        try? await Task.sleep(for: .milliseconds(100))

        #expect(fixture.recordingService.captureHealthSnapshotCallCount == countAfterStop)
        #expect(fixture.viewModel.lastCaptureHealthEffect == .none)
        #expect(!fixture.viewModel.wasCaptureInterrupted)
    }
}

@MainActor
private final class MockNewSessionAppAudioService: AppAudioServiceProtocol {
    var runningApps: [CapturedApp] = []
    var selectedApp: CapturedApp?
    var refreshCalls = 0
    var incrementUsageCalls: [String] = []

    func incrementUsage(for bundleID: String) {
        incrementUsageCalls.append(bundleID)
    }

    func refreshRunningApps() {
        refreshCalls += 1
    }
}

@MainActor
private final class MockScreenCaptureService: ScreenCaptureServiceProtocol {
    var availableDisplays: [CaptureDisplay] = []
    var selectedDisplayID: CGDirectDisplayID?
    var refreshCalls = 0

    func refreshAvailableDisplays() async {
        refreshCalls += 1
    }
}
