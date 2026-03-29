import Combine
import Foundation
@testable import Scriberman

@MainActor
final class MockPermissionService: PermissionServiceProtocol {
    @Published var micStatus: PermissionStatus = .notDetermined
    @Published var screenRecordingStatus: PermissionStatus = .notDetermined
    var checkAllCalls = 0
    var requestMicResult = false
    var requestMicCalls = 0
    var requestScreenRecordingResult = false
    var verifyMicResult = false
    var verifyMicCalls = 0
    var verifyScreenRecordingResult = false
    var verifyScreenRecordingCalls = 0
    var onboardingMarked = false
    var needsOnboardingValue = false

    var micStatusPublisher: AnyPublisher<PermissionStatus, Never> {
        $micStatus.eraseToAnyPublisher()
    }

    var screenRecordingStatusPublisher: AnyPublisher<PermissionStatus, Never> {
        $screenRecordingStatus.eraseToAnyPublisher()
    }

    var needsOnboarding: Bool {
        needsOnboardingValue
    }

    func checkAll() {
        checkAllCalls += 1
    }

    func requestMic() async -> Bool {
        requestMicCalls += 1
        micStatus = requestMicResult ? .granted : .denied
        return requestMicResult
    }

    func requestScreenRecording() -> Bool {
        requestScreenRecordingResult
    }

    func verifyMic() async -> Bool {
        verifyMicCalls += 1
        micStatus = verifyMicResult ? .granted : .denied
        return verifyMicResult
    }

    func verifyScreenRecording() async -> Bool {
        verifyScreenRecordingCalls += 1
        screenRecordingStatus = verifyScreenRecordingResult ? .granted : .denied
        return verifyScreenRecordingResult
    }

    func markOnboardingShown() {
        onboardingMarked = true
        needsOnboardingValue = false
    }
}
