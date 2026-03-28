import AVFoundation
import XCTest
@testable import Scriberman

@MainActor
final class PermissionServiceTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var userDefaultsSuiteName: String!
    private var microphonePermissions: MockMicrophonePermissionProvider!
    private var screenRecordingPermissions: MockScreenRecordingPermissionProvider!
    private var service: PermissionService!

    override func setUp() {
        super.setUp()
        userDefaultsSuiteName = "PermissionServiceTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        microphonePermissions = MockMicrophonePermissionProvider()
        screenRecordingPermissions = MockScreenRecordingPermissionProvider()
    }

    override func tearDown() {
        service = nil
        screenRecordingPermissions = nil
        microphonePermissions = nil
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
            userDefaults: userDefaults
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
            userDefaults: userDefaults
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
            userDefaults: userDefaults
        )

        XCTAssertTrue(service.needsOnboarding)

        service.markOnboardingShown()

        XCTAssertFalse(service.needsOnboarding)
        XCTAssertTrue(userDefaults.bool(forKey: PermissionService.DefaultsKey.permissionsOnboardingHasBeenShown))
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
