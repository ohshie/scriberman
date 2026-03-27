import CoreAudio
import Foundation
@testable import Scriberman

final class MockRecordingService: RecordingServiceProtocol {
    var isRecordingOverride = false
    var audioLevelOverride: Float = 0
    var startShouldThrow: Error?
    var startThrowSequence: [Error] = []
    var stopReturns: RecordingSession?
    var startCalls: [(workspace: Workspace, micDeviceID: AudioDeviceID?, tapID: AudioObjectID?, aggregateDeviceID: AudioDeviceID?, capturedAppName: String?)] = []
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
        tapID: AudioObjectID?,
        aggregateDeviceID: AudioDeviceID?,
        capturedAppName: String?
    ) async throws {
        startCalls.append((
            workspace: workspace,
            micDeviceID: micDeviceID,
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID,
            capturedAppName: capturedAppName
        ))
        if !startThrowSequence.isEmpty {
            throw startThrowSequence.removeFirst()
        }
        if let startShouldThrow {
            throw startShouldThrow
        }
    }

    func stopRecording() async -> RecordingSession? {
        stopReturns
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }
}
