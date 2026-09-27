import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// The parts of `SCStream` the session drives, so tests can stand in for a stream that needs live
/// `SCShareableContent` and TCC grants.
protocol ScreenCaptureStreaming: AnyObject {
    func startCapture() async throws
    func stopCapture() async throws
}

extension SCStream: ScreenCaptureStreaming {}

// @unchecked Sendable: `sampleQueue` owns every mutable property. Stream callbacks arrive on it, and
// `start()`, `stop()`, the timeout task and the public accessors reach the state only through
// `sampleQueue.sync`. `process(_:generation:)` is only ever called on `sampleQueue`.
final class ScreenCaptureSession: NSObject, SCStreamDelegate, @unchecked Sendable {
    typealias DisplayProvider = @Sendable () async throws -> [CapturableDisplay]
    typealias StreamFactory = (
        CapturableDisplay,
        SCStreamConfiguration,
        any SCStreamDelegate,
        any SCStreamOutput,
        DispatchQueue
    ) throws -> any ScreenCaptureStreaming

    struct CapturableDisplay {
        let displayID: CGDirectDisplayID
        let width: Int
        let height: Int
        let makeFilter: () -> SCContentFilter
    }

    private let displayProvider: DisplayProvider
    private let streamFactory: StreamFactory
    private let sampleQueue = DispatchQueue(label: "com.scriberman.screen-video.stream")
    private let logger = Logger(subsystem: "Scriberman", category: "ScreenCaptureSession")

    // Owned by `sampleQueue`.
    private var stream: (any ScreenCaptureStreaming)?
    private var streamOutput: StreamOutput?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var lastFramePresentationTime: CMTime?
    private var videoURL: URL?
    private var hasStartedWriting = false
    private var frameCount = 0
    private var frameDeliveryTimeoutTask: Task<Void, Never>?
    /// Increases on every start and stop. A callback or timeout from an earlier value is ignored.
    private var generation = 0
    private var storedOnError: (@Sendable (Error) -> Void)?
    private var storedVideoStartHostTime: HostNanoseconds?
#if DEBUG
    private var beforeAppend: (@Sendable () -> Void)?
#endif

    var onError: (@Sendable (Error) -> Void)? {
        get { sampleQueue.sync { storedOnError } }
        set { sampleQueue.sync { storedOnError = newValue } }
    }

    /// Presentation time of the first frame written to the movie, which is the movie's time zero.
    var videoStartHostTime: HostNanoseconds? {
        sampleQueue.sync { storedVideoStartHostTime }
    }

    init(displayProvider: @escaping DisplayProvider, streamFactory: @escaping StreamFactory = ScreenCaptureSession.makeStream) {
        self.displayProvider = displayProvider
        self.streamFactory = streamFactory
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

        // The writer is in place before capture starts, so a frame delivered the moment the stream
        // comes up has somewhere to go.
        let startedGeneration: Int = sampleQueue.sync {
            generation += 1
            assetWriter = writer
            videoInput = input
            self.videoURL = videoURL
            storedVideoStartHostTime = nil
            lastFramePresentationTime = nil
            hasStartedWriting = false
            frameCount = 0
            return generation
        }

        let output = StreamOutput(session: self, generation: startedGeneration)
        let stream: any ScreenCaptureStreaming
        do {
            stream = try streamFactory(display, configuration, self, output, sampleQueue)
            try await stream.startCapture()
        } catch {
            sampleQueue.sync {
                guard generation == startedGeneration else { return }
                clearWriterState()
            }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: videoURL)
            throw error
        }

        let timeoutTask = Task { [weak self, displayID] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let onError: (@Sendable (Error) -> Void)? = self.sampleQueue.sync {
                guard self.generation == startedGeneration, !self.hasStartedWriting else { return nil }
                return self.storedOnError
            }
            guard let onError else { return }
            self.logger.error(
                "Screen capture produced no frames within 5s for displayID=\(displayID, privacy: .public)"
            )
            onError(RecordingError.failedToStart(
                "Screen capture produced no video frames. The display may be off, disconnected, or not capturable."
            ))
        }

        sampleQueue.sync {
            self.stream = stream
            streamOutput = output
            if generation == startedGeneration, !hasStartedWriting {
                frameDeliveryTimeoutTask = timeoutTask
            } else {
                timeoutTask.cancel()
            }
        }
    }

    func stop() async {
        let stream: (any ScreenCaptureStreaming)? = sampleQueue.sync {
            frameDeliveryTimeoutTask?.cancel()
            frameDeliveryTimeoutTask = nil
            let current = self.stream
            self.stream = nil
            return current
        }

        if let stream {
            try? await stream.stopCapture()
        }

        // Frames already queued on `sampleQueue` run before this block, so an append in progress
        // finishes before the input is marked finished. Anything delivered later is ignored.
        let writerToFinish: AVAssetWriter? = sampleQueue.sync {
            generation += 1
            streamOutput = nil
            logger.info(
                "Screen capture stopping: hasStartedWriting=\(self.hasStartedWriting, privacy: .public) frameCount=\(self.frameCount, privacy: .public)"
            )

            guard let assetWriter, let videoInput else {
                clearWriterState()
                return nil
            }

            defer { clearWriterState() }
            if hasStartedWriting {
                videoInput.markAsFinished()
                if let lastFramePresentationTime, lastFramePresentationTime.isValid {
                    assetWriter.endSession(atSourceTime: lastFramePresentationTime)
                }
                return assetWriter
            }

            assetWriter.cancelWriting()
            if let videoURL {
                try? FileManager.default.removeItem(at: videoURL)
            }
            return nil
        }

        if let writerToFinish {
            await finishWriting(writerToFinish)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        handleStreamStop(error)
    }

    func handleStreamStop(_ error: Error) {
        logger.error("Screen capture stream stopped with error: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }

    /// Runs on `sampleQueue`.
    fileprivate func process(_ sampleBuffer: CMSampleBuffer, generation callbackGeneration: Int) {
        guard callbackGeneration == generation else {
            return
        }
        // An idle or incomplete frame proves nothing about the writer, so it must not start the
        // session, set the anchor or cancel the no-frame timeout.
        guard Self.isCompleteFrame(sampleBuffer) else {
            return
        }
        guard let assetWriter, let videoInput else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !hasStartedWriting {
            guard assetWriter.startWriting() else {
                logger.error(
                    "Failed to start screen video writer: status=\(assetWriter.status.rawValue, privacy: .public) error=\(assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
                storedOnError?(assetWriter.error ?? RecordingError.failedToStart("Video writer failed to start."))
                return
            }
            assetWriter.startSession(atSourceTime: presentationTime)
            hasStartedWriting = true
            storedVideoStartHostTime = HostNanoseconds(presentationTimeOf: sampleBuffer)
            frameDeliveryTimeoutTask?.cancel()
            frameDeliveryTimeoutTask = nil
        }

        guard videoInput.isReadyForMoreMediaData else {
            return
        }

#if DEBUG
        beforeAppend?()
#endif
        guard videoInput.append(sampleBuffer) else {
            logger.error("Failed to append screen frame: \(assetWriter.error?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        frameCount += 1
        lastFramePresentationTime = presentationTime
    }

    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue)
        else {
            return false
        }
        return status == .complete
    }

    /// Runs on `sampleQueue`.
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

    static func makeStream(
        display: CapturableDisplay,
        configuration: SCStreamConfiguration,
        delegate: any SCStreamDelegate,
        output: any SCStreamOutput,
        queue: DispatchQueue
    ) throws -> any ScreenCaptureStreaming {
        let stream = SCStream(filter: display.makeFilter(), configuration: configuration, delegate: delegate)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        return stream
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

#if DEBUG
    var generationForTesting: Int {
        sampleQueue.sync { generation }
    }

    var frameCountForTesting: Int {
        sampleQueue.sync { frameCount }
    }

    /// Delivers a frame on `sampleQueue` as the stream would, tagged with `generation` or, when nil,
    /// the current one.
    func processSampleBufferForTesting(_ sampleBuffer: CMSampleBuffer, generation: Int? = nil) {
        sampleQueue.sync {
            process(sampleBuffer, generation: generation ?? self.generation)
        }
    }

    /// Like `processSampleBufferForTesting`, but returns at once, so a test can stop mid-append.
    func deliverSampleBufferAsyncForTesting(_ sampleBuffer: CMSampleBuffer) {
        // Handed to the queue once and not touched again by the caller.
        nonisolated(unsafe) let buffer = sampleBuffer
        sampleQueue.async { [self] in
            process(buffer, generation: generation)
        }
    }

    func setBeforeAppendForTesting(_ hook: (@Sendable () -> Void)?) {
        sampleQueue.sync { beforeAppend = hook }
    }
#endif
}

/// Forwards one stream's frames tagged with the generation that started it, so a late callback from
/// a stopped stream is recognisable.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private weak var session: ScreenCaptureSession?
    private let generation: Int

    init(session: ScreenCaptureSession, generation: Int) {
        self.session = session
        self.generation = generation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen else {
            return
        }
        session?.process(sampleBuffer, generation: generation)
    }
}
