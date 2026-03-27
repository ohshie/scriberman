import Foundation
@testable import Scriberman

final class MockRecordingService: RecordingServiceProtocol {
    var isRecordingOverride = false
    var audioLevelOverride: Float = 0
    var startShouldThrow: Error?
    var stopReturns: RecordingSession?

    func isRecording() async -> Bool {
        isRecordingOverride
    }

    func audioLevel() async -> Float {
        audioLevelOverride
    }

    func startRecording(in workspace: Workspace) async throws {
        if let startShouldThrow {
            throw startShouldThrow
        }
    }

    func stopRecording() async -> RecordingSession? {
        stopReturns
    }
}
