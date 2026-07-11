import CoreAudio
import CoreGraphics
import Foundation
@testable import Scriberman

final class MockRecordingService: RecordingServiceProtocol, @unchecked Sendable {
    var isRecordingOverride = false
    var audioLevelOverride: Float = 0
    var startShouldThrow: RecordingError?
    var startThrowSequence: [RecordingError] = []
    var startReturns: UUID = UUID()
    var stopReturns: UUID?
    var startCalls: [(workspace: Workspace, micDeviceID: AudioDeviceID?, captureDisplayID: CGDirectDisplayID?, capturedAppName: String?, appProcessID: pid_t?, title: String?)] = []
    var retargetMicCalls: [String?] = []
    var pendingError: RecordingError?

    func liveAudioStream() async -> AsyncStream<([Float], AudioSource, Double)> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func isRecording() async -> Bool {
        isRecordingOverride
    }

    func audioLevel() async -> Float {
        max(audioLevelsOverride.mic, max(audioLevelsOverride.app, audioLevelOverride))
    }

    var audioLevelsOverride: (mic: Float, app: Float) = (0, 0)

    func audioLevels() async -> (mic: Float, app: Float) {
        (max(audioLevelsOverride.mic, audioLevelOverride), audioLevelsOverride.app)
    }

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        captureDisplayID: CGDirectDisplayID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws(RecordingError) -> UUID {
        startCalls.append((
            workspace: workspace,
            micDeviceID: micDeviceID,
            captureDisplayID: captureDisplayID,
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
        return startReturns
    }

    func stopRecording() async -> UUID? {
        stopReturns
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }

    func retargetMic(desiredDeviceUID: String?) async {
        retargetMicCalls.append(desiredDeviceUID)
    }
}
