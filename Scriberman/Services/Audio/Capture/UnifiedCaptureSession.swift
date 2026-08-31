import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// Captures microphone and app audio from a single `SCStream` (macOS 15+
/// `captureMicrophone`), so both tracks share one clock reference and one presentation-time
/// domain. App audio is delivered as `.audio` and microphone as `.microphone`; each is
/// written to its own 48 kHz mono file (with a timing sidecar) by a dedicated handler.
///
/// Used only for the mic+app case (the drift scenario). Mic-only recording keeps the
/// AVAudioEngine path. @unchecked Sendable: state is confined to the async start/stop context
/// and the handlers' own synchronization.
final class UnifiedCaptureSession: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let appFileURL: URL
    private let processID: pid_t
    private let appHandler: AppAudioStreamOutputHandler
    private let micHandler: MicStreamOutputHandler
    private let appQueue = DispatchQueue(label: "com.scriberman.unified.app")
    private let micQueue = DispatchQueue(label: "com.scriberman.unified.mic")
    private let notificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "Scriberman", category: "UnifiedCaptureSession")
    /// Retained so the microphone device can be changed on the running stream (see
    /// `retargetMic(deviceUID:)`) instead of being rebuilt and discarded inside `start()`.
    private let configuration: SCStreamConfiguration
    private var stream: (any UnifiedCaptureStreaming)?

    /// The microphone device identifier the stream is currently configured with. Used by
    /// `RecordingService` to decide whether a device change actually requires a retarget.
    private(set) var currentMicDeviceUID: String?

    var micAudioLevel: Float { micHandler.audioLevel }
    var appAudioLevel: Float { appHandler.audioLevel }
    var micLastActivityAt: Date? { micHandler.lastActivityAt }
    var appLastActivityAt: Date? { appHandler.lastActivityAt }
    var micFramesWritten: Int64 { micHandler.framesWritten }
    var appFramesWritten: Int64 { appHandler.framesWritten }
    var micWriteFailureCount: Int { micHandler.writeFailureCount }
    var appWriteFailureCount: Int { appHandler.writeFailureCount }

    init(
        micFileURL: URL,
        appFileURL: URL,
        processID: pid_t,
        micDeviceUID: String?,
        liveAudioContinuation: AsyncStream<([Float], AudioSource, Double)>.Continuation? = nil,
        onMicFirstHostTime: (@Sendable (UInt64) -> Void)? = nil,
        onAppFirstHostTime: (@Sendable (UInt64) -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.appFileURL = appFileURL
        self.processID = processID
        self.currentMicDeviceUID = micDeviceUID
        self.configuration = Self.makeConfiguration(micDeviceUID: micDeviceUID)
        self.notificationCenter = notificationCenter
        self.appHandler = AppAudioStreamOutputHandler(liveAudioContinuation: liveAudioContinuation)
        self.micHandler = MicStreamOutputHandler(liveAudioContinuation: liveAudioContinuation)
        self.appHandler.onFirstBufferHostTime = onAppFirstHostTime
        self.micHandler.onFirstBufferHostTime = onMicFirstHostTime
        super.init()
        self.appHandler.configureOutput(url: appFileURL)
        self.micHandler.configureOutput(url: micFileURL)
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { $0.processID == processID }) else {
            throw RecordingError.failedToStart("Selected app is not available for audio capture.")
        }
        guard let window = content.windows.first(where: { $0.owningApplication == app }) else {
            throw RecordingError.failedToStart("Selected app has no capturable window.")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(appHandler, type: .audio, sampleHandlerQueue: appQueue)
        try stream.addStreamOutput(micHandler, type: .microphone, sampleHandlerQueue: micQueue)

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await stream.startCapture()
                self.stream = stream
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        throw RecordingError.failedToStart(lastError?.localizedDescription ?? "Failed to start unified capture.")
    }

    private static func makeConfiguration(micDeviceUID: String?) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = micDeviceUID
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 1
        configuration.height = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        return configuration
    }

    /// Switches the microphone captured by the running stream, without stopping, recreating, or
    /// restarting it. App audio is not interrupted and the stream's presentation-time reference is
    /// unchanged, so both sources stay on the timeline established at recording start. The mic
    /// handler is deliberately *not* reconfigured: doing so would reset its timeline anchor and
    /// reopen its output file.
    ///
    /// Returns `false` when the stream is not running or the update was rejected; in that case the
    /// retained configuration is rolled back so it keeps describing what the stream actually has.
    func retargetMic(deviceUID: String?) async -> Bool {
        guard let stream else {
            logger.warning(
                "Mic retarget requested with no running stream. deviceUID=\(deviceUID ?? "<default>", privacy: .public)"
            )
            return false
        }

        let previous = configuration.microphoneCaptureDeviceID
        configuration.microphoneCaptureDeviceID = deviceUID
        do {
            try await stream.updateConfiguration(configuration)
            currentMicDeviceUID = deviceUID
            logger.notice(
                "Mic retargeted on live stream. deviceUID=\(deviceUID ?? "<default>", privacy: .public)"
            )
            return true
        } catch {
            configuration.microphoneCaptureDeviceID = previous
            logger.error(
                "Mic retarget failed; continuing on previous device. deviceUID=\(deviceUID ?? "<default>", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Test seam: attach an already-"started" stream without going through `start()`, which needs
    /// live `SCShareableContent`, a capturable window, and TCC grants.
    func attachStreamForTesting(_ stream: any UnifiedCaptureStreaming) {
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        appHandler.closeOutput()
        micHandler.closeOutput()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("Unified capture stream stopped with error: \(error.localizedDescription, privacy: .public)")
        guard isTCCAccessDeniedError(error) else { return }
        notificationCenter.post(
            name: .appAudioCaptureAccessDenied,
            object: nil,
            userInfo: ["errorDescription": error.localizedDescription]
        )
    }

    nonisolated private func isTCCAccessDeniedError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code),
           code == .userDeclined {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("tcc access denied") || (message.contains("tcc") && message.contains("denied"))
    }
}
