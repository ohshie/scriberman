import AVFoundation
import CoreGraphics
import Foundation

enum RecordingPermissionService {
    static func ensureRecordingPermissions() async throws(RecordingError) {
        try await ensureRecordingPermissions(
            screenPermission: { CGPreflightScreenCaptureAccess() },
            microphonePermission: ensureMicrophonePermission
        )
    }

    static func ensureRecordingPermissions(
        screenPermission: () -> Bool,
        microphonePermission: () async throws(RecordingError) -> Void
    ) async throws(RecordingError) {
        guard screenPermission() else {
            throw RecordingError.failedToStart("Screen recording permission denied")
        }
        try await microphonePermission()
    }

    static func ensureMicrophonePermission() async throws(RecordingError) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }

            guard granted else {
                throw RecordingError.microphoneDenied
            }
        case .restricted, .denied:
            throw RecordingError.microphoneDenied
        @unknown default:
            throw RecordingError.microphoneDenied
        }
    }
}
