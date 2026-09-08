import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

// @unchecked Sendable: delegate callbacks synchronize via sampleQueue (DispatchQueue) and self.stream is only mutated on the calling async context
final class AppAudioCaptureSession: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let fileURL: URL
    private let processID: pid_t
    private let outputHandler: AppAudioStreamOutputHandler
    private let sampleQueue = DispatchQueue(label: "com.scriberman.app-audio.stream")
    private let notificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "Scriberman", category: "AppAudioCaptureSession")
    /// Guards `_stream`, which is read and cleared from the nonisolated `SCStreamDelegate`
    /// callback as well as from the async start/stop context.
    private let streamLock = NSLock()
    private var _stream: SCStream?

    private var stream: SCStream? {
        streamLock.lock()
        defer { streamLock.unlock() }
        return _stream
    }

    private func setStream(_ newValue: SCStream?) {
        streamLock.lock()
        _stream = newValue
        streamLock.unlock()
    }

    /// Clears the retained stream and returns what it was, so a caller can stop it exactly once.
    @discardableResult
    private func takeStream() -> SCStream? {
        streamLock.lock()
        defer { streamLock.unlock() }
        let existing = _stream
        _stream = nil
        return existing
    }

    /// Invoked for every error the stream delegate receives, TCC denials included, so the owning
    /// recording can react instead of the failure ending in a log line. Set by `RecordingService`.
    var onStreamStopped: (@Sendable (any Error) -> Void)?

    var audioLevel: Float {
        outputHandler.audioLevel
    }

    /// When app audio last produced sustained activity (see `CaptureActivityTracker`).
    var lastActivityAt: Date? {
        outputHandler.lastActivityAt
    }

    var framesWritten: Int64 { outputHandler.framesWritten }

    var writeFailureCount: Int { outputHandler.writeFailureCount }

    init(
        fileURL: URL,
        processID: pid_t,
        onFirstBufferHostTime: (@Sendable (UInt64) -> Void)? = nil,
        liveAudioContinuation: AsyncStream<([Float], AudioSource, Double)>.Continuation? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.fileURL = fileURL
        self.processID = processID
        self.notificationCenter = notificationCenter
        self.outputHandler = AppAudioStreamOutputHandler(liveAudioContinuation: liveAudioContinuation)
        outputHandler.onFirstBufferHostTime = onFirstBufferHostTime
        super.init()
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
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 1
        configuration.height = 1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        outputHandler.configureOutput(url: fileURL)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(
            outputHandler,
            type: .audio,
            sampleHandlerQueue: sampleQueue
        )

        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await stream.startCapture()
                setStream(stream)
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }

        throw RecordingError.failedToStart(lastError?.localizedDescription ?? "Failed to start app audio capture.")
    }

    func stop() async {
        if let stream = takeStream() {
            try? await stream.stopCapture()
        }
        outputHandler.closeOutput()
    }

    /// Stops the stream but leaves the output writer open, so the file stays open, no `.timing`
    /// sidecar is written, and the accumulated timing segments survive. Used by the mid-session
    /// restart; callers finishing a recording must use `stop()` instead.
    func stopStreamPreservingOutput() async {
        if let stream = takeStream() {
            try? await stream.stopCapture()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        handleStreamStopped(error)
    }

#if DEBUG
    /// Test seam: drive the stream-stopped path without an `SCStream`, which cannot be constructed
    /// in tests.
    func handleStreamStoppedForTesting(_ error: any Error) {
        handleStreamStopped(error)
    }
#endif

    nonisolated private func handleStreamStopped(_ error: any Error) {
        logger.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription, privacy: .public)")

        // The stream is gone; stop reporting it as an active capture before anyone reacts.
        takeStream()

        if isTCCAccessDeniedError(error) {
            logger.error("Detected TCC access denial from stream delegate.")
            notificationCenter.post(
                name: .appAudioCaptureAccessDenied,
                object: nil,
                userInfo: ["errorDescription": error.localizedDescription]
            )
        }

        // Reported for every error, not just TCC.
        onStreamStopped?(error)
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
