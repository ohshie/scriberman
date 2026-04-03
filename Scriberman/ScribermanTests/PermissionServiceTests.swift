import AVFoundation
import Testing
@testable import Scriberman

@MainActor
final class PermissionServiceTests {
    nonisolated(unsafe) private var userDefaults: UserDefaults!
    nonisolated(unsafe) private var userDefaultsSuiteName: String!
    nonisolated(unsafe) private var notificationCenter: NotificationCenter!
    nonisolated(unsafe) private var microphonePermissions: MockMicrophonePermissionProvider!
    nonisolated(unsafe) private var screenRecordingPermissions: MockScreenRecordingPermissionProvider!
    nonisolated(unsafe) private var functionalPermissions: MockScreenRecordingFunctionalPermissionProvider!
    nonisolated(unsafe) private var service: PermissionService!

    init() {
        userDefaultsSuiteName = "PermissionServiceTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        notificationCenter = NotificationCenter()
        microphonePermissions = MockMicrophonePermissionProvider()
        screenRecordingPermissions = MockScreenRecordingPermissionProvider()
        functionalPermissions = MockScreenRecordingFunctionalPermissionProvider()
    }

    deinit {
        service = nil
        functionalPermissions = nil
        screenRecordingPermissions = nil
        microphonePermissions = nil
        notificationCenter = nil
        if let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        userDefaults = nil
        userDefaultsSuiteName = nil
    }

    @Test

    func testMicTransitionsFromNotDeterminedToGrantedAfterRequest() async {
        microphonePermissions.status = .notDetermined
        microphonePermissions.requestResult = true
        microphonePermissions.statusAfterRequest = .authorized
        screenRecordingPermissions.preflightResult = true

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.micStatus == .notDetermined)

        let granted = await service.requestMic()

        #expect(granted)
        #expect(service.micStatus == .granted)
    }

    @Test

    func testScreenRecordingStatusSynthesizesNotDeterminedThenDeniedAfterRequest() {
        microphonePermissions.status = .authorized
        screenRecordingPermissions.preflightResult = false
        screenRecordingPermissions.requestResult = false

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.screenRecordingStatus == .notDetermined)

        _ = service.requestScreenRecording()

        #expect(service.screenRecordingStatus == .denied)
        #expect(userDefaults.bool(forKey: PermissionService.DefaultsKey.screenRecordingPromptHasBeenShown))
    }

    @Test

    func testCheckAllMapsScreenRecordingToDeniedWhenPromptWasShownAndPreflightIsFalse() {
        microphonePermissions.status = .authorized
        screenRecordingPermissions.preflightResult = false
        userDefaults.set(true, forKey: PermissionService.DefaultsKey.screenRecordingPromptHasBeenShown)

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        #expect(service.screenRecordingStatus == .denied)
    }

    @Test

    func testVerifyMicRechecksCurrentAuthorizationStatus() async {
        microphonePermissions.status = .notDetermined
        screenRecordingPermissions.preflightResult = false

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        microphonePermissions.status = .authorized
        let granted = await service.verifyMic()

        #expect(granted)
        #expect(service.micStatus == .granted)
    }

    @Test

    func testVerifyScreenRecordingReturnsFalseWhenPreflightDenied() async {
        microphonePermissions.status = .authorized
        screenRecordingPermissions.preflightResult = false
        userDefaults.set(true, forKey: PermissionService.DefaultsKey.screenRecordingPromptHasBeenShown)

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        let granted = await service.verifyScreenRecording()

        #expect(!(granted))
        #expect(service.screenRecordingStatus == .denied)
    }

    @Test

    func testVerifyScreenRecordingRequiresFunctionalShareableContent() async {
        microphonePermissions.status = .authorized
        screenRecordingPermissions.preflightResult = true
        functionalPermissions.snapshotResult = ScreenRecordingShareableContentSnapshot(
            windowCount: 0,
            applicationCount: 0
        )

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        let granted = await service.verifyScreenRecording()

        #expect(!(granted))
        #expect(service.screenRecordingStatus == .denied)
    }

    @Test

    func testVerifyScreenRecordingSucceedsWhenShareableContentExists() async {
        microphonePermissions.status = .authorized
        screenRecordingPermissions.preflightResult = true
        functionalPermissions.snapshotResult = ScreenRecordingShareableContentSnapshot(
            windowCount: 2,
            applicationCount: 1
        )

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        let granted = await service.verifyScreenRecording()

        #expect(granted)
        #expect(service.screenRecordingStatus == .granted)
    }

    @Test

    func testAppAudioCaptureDeniedNotificationForcesScreenStatusDenied() async {
        microphonePermissions.status = .authorized
        screenRecordingPermissions.preflightResult = true

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )
        #expect(service.screenRecordingStatus == .granted)

        notificationCenter.post(
            name: .appAudioCaptureAccessDenied,
            object: nil,
            userInfo: ["errorDescription": "TCC Access Denied"]
        )

        await Task.yield()
        #expect(service.screenRecordingStatus == .denied)
        #expect(userDefaults.bool(forKey: PermissionService.DefaultsKey.screenRecordingPromptHasBeenShown))
    }
}

@MainActor
private final class MockMicrophonePermissionProvider: MicrophonePermissionProviding {
    var status: AVAuthorizationStatus = .notDetermined
    var statusAfterRequest: AVAuthorizationStatus?
    var requestResult = false

    func authorizationStatus() -> AVAuthorizationStatus {
        status
    }

    func requestAccess() async -> Bool {
        if let statusAfterRequest {
            status = statusAfterRequest
        }
        return requestResult
    }
}

@MainActor
private final class MockScreenRecordingPermissionProvider: ScreenRecordingPermissionProviding {
    var preflightResult = false
    var requestResult = false

    func preflightAccess() -> Bool {
        preflightResult
    }

    func requestAccess() -> Bool {
        requestResult
    }
}

@MainActor
private final class MockScreenRecordingFunctionalPermissionProvider: ScreenRecordingFunctionalPermissionProviding {
    var snapshotResult = ScreenRecordingShareableContentSnapshot(
        windowCount: 1,
        applicationCount: 1
    )
    var errorToThrow: Error?

    func shareableContentSnapshot() async throws -> ScreenRecordingShareableContentSnapshot {
        if let errorToThrow {
            throw errorToThrow
        }
        return snapshotResult
    }
}
