import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

// @unchecked Sendable: stream callbacks serialize on sampleQueue and mutable state stays within this instance.
final class ScreenCaptureSession: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    typealias DisplayProvider = @Sendable () async throws -> [CapturableDisplay]

    struct CapturableDisplay {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let makeFilter: () -> SCContentFilter
    }

    private let displayProvider: DisplayProvider
    private let sampleQueue = DispatchQueue(label: "com.scriberman.screen-video.stream")
    private let logger = Logger(subsystem: "Scriberman", category: "ScreenCaptureSession")

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var lastFramePresentationTime: CMTime?
    private var videoURL: URL?
    private var hasStartedWriting = false
    private var frameCount = 0
    // frameDeliveryTimeoutTask: Task.cancel() is thread-safe; cancelled from both sampleQueue and actor context.
    private var frameDeliveryTimeoutTask: Task<Void, Never>?

    var onError: (@Sendable (Error) -> Void)?
    var videoStartHostTime: UInt64?

    init(displayProvider: @escaping DisplayProvider) {
        self.displayProvider = displayProvider
        super.init()
    }

    override convenience init() {
        self.init(displayProvider: Self.defaultDisplayProvider)
    }

    func start(displayID: CGDirectDisplayID, videoURL: URL) async throws {
        let displays = try await displayProvider()
        guard let display = displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.failedToStart("Selected display is not available for screen capture.")
        }

        let captureWidth = (display.width / 2) * 2
        let captureHeight = (display.height / 2) * 2
        logger.info(
            "Starting screen capture: displayID=\(displayID, privacy: .public) source=\(display.width)x\(display.height) output=\(captureWidth)x\(captureHeight)"
        )

        let filter = display.makeFilter()
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.width = captureWidth
        configuration.height = captureHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5

        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: captureWidth,
            AVVideoHeightKey: captureHeight
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecordingError.failedToStart("Unable to configure screen video writer.")
        }

        writer.add(input)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        self.assetWriter = writer
        self.videoInput = input
        self.videoURL = videoURL
        self.videoStartHostTime = nil
        self.lastFramePresentationTime = nil
        self.hasStartedWriting = false
        self.frameCount = 0

        frameDeliveryTimeoutTask = Task { [weak self, displayID] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.hasStartedWriting else { return }
            self.logger.error(
                "Screen capture produced no frames within 5s for displayID=\(displayID, privacy: .public)"
            )
            self.onError?(RecordingError.failedToStart(
                "Screen capture produced no video frames. The display may be off, disconnected, or not capturable."
            ))
        }
    }

    func stop() async {
        frameDeliveryTimeoutTask?.cancel()
        frameDeliveryTimeoutTask = nil

        if let stream {
            try? await stream.stopCapture()
        }
        self.stream = nil

        logger.info(
            "Screen capture stopping: hasStartedWriting=\(self.hasStartedWriting, privacy: .public) frameCount=\(self.frameCount, privacy: .public)"
        )

        guard let assetWriter, let videoInput else {
            clearWriterState()
            return
        }

        if hasStartedWriting {
            videoInput.markAsFinished()
            if let lastFramePresentationTime, lastFramePresentationTime.isValid {
                assetWriter.endSession(atSourceTime: lastFramePresentationTime)
            }
            await finishWriting(assetWriter)
        } else {
            assetWriter.cancelWriting()
            if let videoURL {
                try? FileManager.default.removeItem(at: videoURL)
            }
        }

        clearWriterState()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else {
            return
        }
        process(sampleBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        handleStreamStop(error)
    }

    func captureVideoStartHostTimeIfNeeded(from sampleBuffer: CMSampleBuffer) {
        guard videoStartHostTime == nil else {
            return
        }

        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTimeClock = CMClockGetHostTimeClock()
        let hostTime = CMSyncConvertTime(
            presentationTimestamp,
            from: hostTimeClock,
            to: hostTimeClock
        )

        guard CMTIME_IS_VALID(hostTime), CMTIME_IS_NUMERIC(hostTime) else {
            return
        }

        videoStartHostTime = CMClockConvertHostTimeToSystemUnits(hostTime)
    }

    func handleStreamStop(_ error: Error) {
        logger.error("Screen capture stream stopped with error: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        // Cancel the no-frame timeout: frames are arriving.
        if !hasStartedWriting {
            frameDeliveryTimeoutTask?.cancel()
            frameDeliveryTimeoutTask = nil
        }

        captureVideoStartHostTimeIfNeeded(from: sampleBuffer)

        guard let assetWriter, let videoInput else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !hasStartedWriting {
            guard assetWriter.startWriting() else {
                logger.error(
                    "Failed to start screen video writer: status=\(assetWriter.status.rawValue, privacy: .public) error=\(assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
                onError?(assetWriter.error ?? RecordingError.failedToStart("Video writer failed to start."))
                return
            }
            assetWriter.startSession(atSourceTime: presentationTime)
            hasStartedWriting = true
        }

        guard videoInput.isReadyForMoreMediaData else {
            return
        }

        guard videoInput.append(sampleBuffer) else {
            logger.error("Failed to append screen frame: \(assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        frameCount += 1
        lastFramePresentationTime = presentationTime
    }

    private func clearWriterState() {
        assetWriter = nil
        videoInput = nil
        videoURL = nil
        lastFramePresentationTime = nil
        hasStartedWriting = false
        frameCount = 0
    }

    private func finishWriting(_ assetWriter: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            assetWriter.finishWriting {
                continuation.resume()
            }
        }
    }

    private static func defaultDisplayProvider() async throws -> [CapturableDisplay] {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        return shareableContent.displays.map { display in
            CapturableDisplay(
                displayID: display.displayID,
                width: display.width,
                height: display.height,
                makeFilter: {
                    SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                }
            )
        }
    }
}
