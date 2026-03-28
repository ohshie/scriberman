import Combine
import Foundation
@testable import Scriberman

@MainActor
final class MockPermissionService: PermissionServiceProtocol {
    @Published var micStatus: PermissionStatus = .notDetermined
    @Published var screenRecordingStatus: PermissionStatus = .notDetermined
    var checkAllCalls = 0
    var requestMicResult = false
    var requestScreenRecordingResult = false
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
        requestMicResult
    }

    func requestScreenRecording() -> Bool {
        requestScreenRecordingResult
    }

    func markOnboardingShown() {
        onboardingMarked = true
        needsOnboardingValue = false
    }
}
