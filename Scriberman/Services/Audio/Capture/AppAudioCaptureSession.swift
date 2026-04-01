import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

final class AppAudioCaptureSession: NSObject, SCStreamDelegate {
    private let fileURL: URL
    private let processID: pid_t
    private let outputHandler: AppAudioStreamOutputHandler
    private let sampleQueue = DispatchQueue(label: "com.scriberman.app-audio.stream")
    private let notificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "Scriberman", category: "AppAudioCaptureSession")
    private var stream: SCStream?

    var audioLevel: Float {
        outputHandler.audioLevel
    }

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
                self.stream = stream
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
        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil
        outputHandler.closeOutput()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription, privacy: .public)")

        guard isTCCAccessDeniedError(error) else {
            return
        }

        logger.error("Detected TCC access denial from stream delegate.")
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
