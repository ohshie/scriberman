import AVFoundation
import Foundation

@MainActor
protocol MicrophonePermissionProviding {
    func authorizationStatus() -> AVAuthorizationStatus
    func requestAccess() async -> Bool
}

struct AVCaptureMicrophonePermissionProvider: MicrophonePermissionProviding {
    func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
