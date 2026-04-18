import AVFoundation
import CoreAudio
import Foundation
import SwiftData

protocol RecordingServiceProtocol: Sendable {
    func liveAudioStream() async -> AsyncStream<([Float], AudioSource, Double)>
    func isRecording() async -> Bool
    func audioLevel() async -> Float
    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws(RecordingError) -> UUID
    func stopRecording() async -> UUID?
    func consumePendingError() async -> RecordingError?
    func retargetMic(desiredDeviceUID: String?) async
}
