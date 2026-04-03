import Foundation
@testable import Scriberman

@MainActor
final class MockPermissionService: PermissionServiceProtocol {
    var micStatus: PermissionStatus = .notDetermined
    var screenRecordingStatus: PermissionStatus = .notDetermined
    var checkAllCalls = 0
    var requestMicResult = false
    var requestMicCalls = 0
    var requestScreenRecordingResult = false
    var requestScreenRecordingCalls = 0
    var verifyMicResult = false
    var verifyMicCalls = 0
    var verifyScreenRecordingResult = false
    var verifyScreenRecordingCalls = 0

    func checkAll() {
        checkAllCalls += 1
    }

    func requestMic() async -> Bool {
        requestMicCalls += 1
        micStatus = requestMicResult ? .granted : .denied
        return requestMicResult
    }

    func requestScreenRecording() -> Bool {
        requestScreenRecordingCalls += 1
        return requestScreenRecordingResult
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
}
