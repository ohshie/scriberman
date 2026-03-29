import AVFoundation
import XCTest
@testable import Scriberman

@MainActor
final class PermissionServiceTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var notificationCenter: NotificationCenter!
    private var microphonePermissions: MockMicrophonePermissionProvider!
    private var screenRecordingPermissions: MockScreenRecordingPermissionProvider!
    private var functionalPermissions: MockScreenRecordingFunctionalPermissionProvider!
    private var service: PermissionService!

    override func setUp() {
        super.setUp()
        userDefaultsSuiteName = "PermissionServiceTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        notificationCenter = NotificationCenter()
        microphonePermissions = MockMicrophonePermissionProvider()
        screenRecordingPermissions = MockScreenRecordingPermissionProvider()
        functionalPermissions = MockScreenRecordingFunctionalPermissionProvider()
    }

    override func tearDown() {
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
        super.tearDown()
    }

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

        XCTAssertEqual(service.micStatus, .notDetermined)

        let granted = await service.requestMic()

        XCTAssertTrue(granted)
        XCTAssertEqual(service.micStatus, .granted)
    }

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

        XCTAssertEqual(service.screenRecordingStatus, .notDetermined)

        _ = service.requestScreenRecording()

        XCTAssertEqual(service.screenRecordingStatus, .denied)
        XCTAssertTrue(userDefaults.bool(forKey: PermissionService.DefaultsKey.screenRecordingPromptHasBeenShown))
    }

    func testNeedsOnboardingTrueWhenUndeterminedAndFalseAfterMarkingShown() {
        microphonePermissions.status = .notDetermined
        screenRecordingPermissions.preflightResult = false

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        XCTAssertTrue(service.needsOnboarding)

        service.markOnboardingShown()

        XCTAssertFalse(service.needsOnboarding)
        XCTAssertTrue(userDefaults.bool(forKey: PermissionService.DefaultsKey.permissionsOnboardingHasBeenShown))
    }

    func testNeedsOnboardingTrueWhenPermissionDeniedAndOnboardingNotMarked() {
        microphonePermissions.status = .denied
        screenRecordingPermissions.preflightResult = false
        userDefaults.set(true, forKey: PermissionService.DefaultsKey.screenRecordingPromptHasBeenShown)

        service = PermissionService(
            microphonePermissions: microphonePermissions,
            screenRecordingPermissions: screenRecordingPermissions,
            screenRecordingFunctionalPermissions: functionalPermissions,
            userDefaults: userDefaults,
            notificationCenter: notificationCenter
        )

        XCTAssertTrue(service.needsOnboarding)
    }

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

        XCTAssertTrue(granted)
        XCTAssertEqual(service.micStatus, .granted)
    }

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

        XCTAssertFalse(granted)
        XCTAssertEqual(service.screenRecordingStatus, .denied)
    }

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

        XCTAssertFalse(granted)
        XCTAssertEqual(service.screenRecordingStatus, .denied)
    }

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

        XCTAssertTrue(granted)
        XCTAssertEqual(service.screenRecordingStatus, .granted)
    }

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
        XCTAssertEqual(service.screenRecordingStatus, .granted)

        notificationCenter.post(
            name: .appAudioCaptureAccessDenied,
            object: nil,
            userInfo: ["errorDescription": "TCC Access Denied"]
        )

        await Task.yield()
        XCTAssertEqual(service.screenRecordingStatus, .denied)
        XCTAssertTrue(userDefaults.bool(forKey: PermissionService.DefaultsKey.screenRecordingPromptHasBeenShown))
    }
}

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
