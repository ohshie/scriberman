import AVFoundation
import CoreAudio
import Foundation
import SwiftData

protocol RecordingServiceProtocol {
    func liveAudioStream() async -> AsyncStream<([Float], AudioSource, Double)>
    func isRecording() async -> Bool
    func audioLevel() async -> Float
    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws
    func stopRecording() async -> UUID?
    func consumePendingError() async -> RecordingError?
}
