import CoreAudio
import Foundation
@testable import Scriberman

final class MockRecordingService: RecordingServiceProtocol {
    var isRecordingOverride = false
    var audioLevelOverride: Float = 0
    var startShouldThrow: Error?
    var startThrowSequence: [Error] = []
    var stopReturns: UUID?
    var startCalls: [(workspace: Workspace, micDeviceID: AudioDeviceID?, capturedAppName: String?, appProcessID: pid_t?, title: String?)] = []
    var pendingError: RecordingError?

    func isRecording() async -> Bool {
        isRecordingOverride
    }

    func audioLevel() async -> Float {
        audioLevelOverride
    }

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws {
        startCalls.append((
            workspace: workspace,
            micDeviceID: micDeviceID,
            capturedAppName: capturedAppName,
            appProcessID: appProcessID,
            title: title
        ))
        if !startThrowSequence.isEmpty {
            throw startThrowSequence.removeFirst()
        }
        if let startShouldThrow {
            throw startShouldThrow
        }
    }

    func stopRecording() async -> UUID? {
        stopReturns
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }
}
