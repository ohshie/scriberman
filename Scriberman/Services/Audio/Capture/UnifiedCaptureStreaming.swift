import Foundation
import ScreenCaptureKit

/// The subset of `SCStream` that `UnifiedCaptureSession` actually drives.
///
/// Exists so the session's lifecycle and mic-retarget logic can be exercised without a real
/// capture stream: constructing an `SCStream` requires live `SCShareableContent`, a capturable
/// window, and Screen Recording + Microphone TCC grants, none of which are available in tests.
protocol UnifiedCaptureStreaming: AnyObject {
    func addStreamOutput(
        _ output: SCStreamOutput,
        type: SCStreamOutputType,
        sampleHandlerQueue: DispatchQueue?
    ) throws
    func startCapture() async throws
    func stopCapture() async throws
    func updateConfiguration(_ configuration: SCStreamConfiguration) async throws
}

extension SCStream: UnifiedCaptureStreaming {}
