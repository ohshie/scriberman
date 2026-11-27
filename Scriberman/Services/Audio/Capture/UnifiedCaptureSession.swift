import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

/// Captures microphone and app audio from a single `SCStream` (macOS 15+
/// `captureMicrophone`), so both tracks share one clock reference and one presentation-time
/// domain. App audio is delivered as `.audio` and microphone as `.microphone`; each is
/// written to its own 48 kHz mono file (with a timing sidecar) by a dedicated handler.
///
/// Mic-only capture has a display filter and only a microphone output.
/// @unchecked Sendable: state is confined to the async start/stop context
/// and the handlers' own synchronization.
final class UnifiedCaptureSession: NSObject, SCStreamDelegate, @unchecked Sendable {
    struct AppSource: Sendable {
        let fileURL: URL
        let processID: pid_t
    }

    let appSource: AppSource?
    private var appFileURL: URL? { appSource?.fileURL }
    /// The app whose audio is captured. Nil for a mic-only stream: no app audio, a display filter, and only the microphone output.
    private var processID: pid_t? { appSource?.processID }
    let appHandler: AppAudioStreamOutputHandler
    let micHandler: MicStreamOutputHandler
    private let appQueue = DispatchQueue(label: "com.scriberman.unified.app")
    private let micQueue = DispatchQueue(label: "com.scriberman.unified.mic")
    private let notificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "Scriberman", category: "UnifiedCaptureSession")
    /// Retained so the microphone device can be changed on the running stream (see
    /// `retargetMic(deviceUID:)`) instead of being rebuilt and discarded inside `start()`.
    let configuration: SCStreamConfiguration
    var hasAppSource: Bool { appSource != nil }
    /// Guards `_stream`, which is read and cleared from the nonisolated `SCStreamDelegate`
    /// callback as well as from the async start/stop context.
    private let streamLock = NSLock()
    private var _stream: (any UnifiedCaptureStreaming)?
    private var retired = false
    private var switchTimedOut = false
    var micSwitchTimedOut: Bool { streamLock.withLock { switchTimedOut } }

    private var stream: (any UnifiedCaptureStreaming)? {
        streamLock.lock()
        defer { streamLock.unlock() }
        return _stream
    }

    @discardableResult
    private func setStream(_ newValue: (any UnifiedCaptureStreaming)?) -> Bool {
        streamLock.withLock {
            guard !retired else { return false }
            _stream = newValue
            return true
        }
    }

    /// Clears the retained stream and returns what it was, so a caller can stop it exactly once.
    @discardableResult
    private func takeStream() -> (any UnifiedCaptureStreaming)? {
        streamLock.lock()
        defer { streamLock.unlock() }
        let existing = _stream
        _stream = nil
        return existing
    }

    /// False once the stream has stopped on its own (or been stopped), true while it runs.
    var isStreamLive: Bool { stream != nil }

    /// Invoked for every error the stream delegate receives, TCC denials included, so the owning
    /// recording can react instead of the failure ending in a log line. Set by `RecordingService`.
    var onStreamStopped: (@Sendable (any Error) -> Void)?

    /// The microphone device identifier the stream is currently configured with. Used by
    /// `RecordingService` to decide whether a device change actually requires a retarget.
    private var configuredMicDeviceUID: String?
    var currentMicDeviceUID: String? { streamLock.withLock { configuredMicDeviceUID } }

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
        appFileURL: URL?,
        processID: pid_t?,
        micDeviceUID: String?,
        liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation? = nil,
        onMicFirstHostTime: (@Sendable (HostNanoseconds) -> Void)? = nil,
        onAppFirstHostTime: (@Sendable (HostNanoseconds) -> Void)? = nil,
        notificationCenter: NotificationCenter = .default,
        reusingStreamers: (mic: AudioFileStreamer, app: AudioFileStreamer)? = nil,
        preparedStreamers: (mic: Bool, app: Bool) = (true, true),
        gates: RecordingCaptureGates = RecordingCaptureGates()
    ) {
        let appSource = if let appFileURL, let processID {
            AppSource(fileURL: appFileURL, processID: processID)
        } else {
            nil as AppSource?
        }
        self.appSource = appSource
        self.configuredMicDeviceUID = micDeviceUID
        self.configuration = Self.makeConfiguration(micDeviceUID: micDeviceUID, capturesAppAudio: appSource != nil)
        self.notificationCenter = notificationCenter
        self.appHandler = AppAudioStreamOutputHandler(
            liveAudioContinuation: liveAudioContinuation,
            streamer: reusingStreamers?.app ?? AudioFileStreamer(label: "app"),
            gate: gates.app
        )
        self.micHandler = MicStreamOutputHandler(
            liveAudioContinuation: liveAudioContinuation,
            streamer: reusingStreamers?.mic ?? AudioFileStreamer(label: "mic"),
            gate: gates.mic
        )
        self.appHandler.onFirstBufferHostTime = onAppFirstHostTime
        self.micHandler.onFirstBufferHostTime = onMicFirstHostTime
        super.init()
        // A mid-session restart adopts writers that are already open and mid-recording. Preparing
        // them again would truncate the files and reset their timing segments, which is exactly the
        // audio a restart exists to preserve.
        // A reused writer that its source never opened is prepared on the first buffer, as at start.
        if let appFileURL = appSource?.fileURL {
            if reusingStreamers != nil, preparedStreamers.app {
                self.appHandler.adoptPreparedOutput(url: appFileURL)
            } else {
                self.appHandler.configureOutput(url: appFileURL)
            }
        }
        if reusingStreamers != nil, preparedStreamers.mic {
            self.micHandler.adoptPreparedOutput(url: micFileURL)
        } else {
            self.micHandler.configureOutput(url: micFileURL)
        }
    }

    /// The writers this session is feeding, so a replacement session can adopt them.
    var streamers: (mic: AudioFileStreamer, app: AudioFileStreamer) {
        (micHandler.streamer, appHandler.streamer)
    }

    /// Which of those writers are open.
    var preparedStreamers: (mic: Bool, app: Bool) {
        (micHandler.isOutputPrepared, appHandler.isOutputPrepared)
    }

    func start() async throws {
        try await start(discoverStream: { [self] in try await discoverStream() })
    }

    /// The discovery seam also covers filter construction and output registration. Content and
    /// all start attempts share one deadline, rather than each receiving another two seconds.
    func start(discoverStream: @escaping @Sendable () async throws -> CaptureStreamReference) async throws {
        let deadline = ContinuousClock.now + BoundedCaptureCall.startLimit
        do {
            let reference = try await BoundedCaptureCall.run(
                call: "shareableContent", device: currentMicDeviceUID, until: deadline,
                onAbandon: { [self] in invalidateOutputs() },
                lateResult: { [self] result in
                    if case .success(let reference) = result { await stopAbandoned(reference) }
                }, operation: discoverStream
            )
            try await start(stream: reference.stream, deadline: deadline)
        } catch is BoundedCaptureCall.TimedOut {
            throw RecordingError.noAudioAtStart
        }
    }

    private func discoverStream() async throws -> CaptureStreamReference {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let processID else {
            // Mic only: the filter needs some content; the main display is used, with no window
            // excluded. No `.screen` or `.audio` output is added, so only microphone buffers are
            // delivered to Scriberman.
            let mainDisplayID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) else {
                throw RecordingError.failedToStart("No display is available for the microphone stream.")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            CaptureTrace.log(
                "micOnlyStreamConfig",
                "filter=display(\(display.displayID)) excludingWindows=[] capturesAudio=\(configuration.capturesAudio) captureMicrophone=\(configuration.captureMicrophone) mic=\(configuration.microphoneCaptureDeviceID ?? "<default>") size=\(configuration.width)x\(configuration.height) minimumFrameInterval=\(configuration.minimumFrameInterval.seconds)s queueDepth=\(configuration.queueDepth) outputs=[microphone]"
            )
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try addOutputs(to: stream)
            return CaptureStreamReference(stream: stream)
        }
        guard let app = content.applications.first(where: { $0.processID == processID }) else {
            throw RecordingError.failedToStart("Selected app is not available for audio capture.")
        }
        guard let window = content.windows.first(where: { $0.owningApplication == app }) else {
            throw RecordingError.failedToStart("Selected app has no capturable window.")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try addOutputs(to: stream)

        return CaptureStreamReference(stream: stream)
    }

    func addOutputs(to stream: any UnifiedCaptureStreaming) throws {
        if hasAppSource {
            try stream.addStreamOutput(appHandler, type: .audio, sampleHandlerQueue: appQueue)
        }
        try stream.addStreamOutput(micHandler, type: .microphone, sampleHandlerQueue: micQueue)
    }

    /// Drives the same retry path for real streams and hardware-free test streams.
    func start(
        stream: any UnifiedCaptureStreaming, retryDelay: Duration = .milliseconds(300),
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let deadline = deadline ?? ContinuousClock.now + BoundedCaptureCall.startLimit
        let reference = CaptureStreamReference(stream: stream)
        var lastError: Error?
        for attempt in 0..<3 {
            if Task.isCancelled {
                invalidateOutputs()
                await stopAbandoned(reference)
                throw CancellationError()
            }
            let startEnd = CaptureTrace.begin("streamStart", "attempt=\(attempt) micOnly=\(processID == nil)")
            do {
                try await BoundedCaptureCall.run(
                    call: "startCapture", device: currentMicDeviceUID, until: deadline,
                    onAbandon: { [self] in invalidateOutputs() },
                    lateResult: { [self] _ in await stopAbandoned(reference) }
                ) { try await reference.stream.startCapture() }
                startEnd("ok")
                try Task.checkCancellation()
                guard setStream(stream) else {
                    await stopAbandoned(reference)
                    throw CancellationError()
                }
                return
            } catch {
                startEnd(error is CancellationError ? "cancelled" : "error \(error.localizedDescription)")
                if error is BoundedCaptureCall.TimedOut {
                    throw RecordingError.noAudioAtStart
                }
                if error is CancellationError {
                    invalidateOutputs()
                    // The pending call owns late cleanup. If cancellation arrived after it
                    // completed, stop here as well; stopping the abandoned stream is idempotent.
                    await stopAbandoned(reference)
                    throw error
                }
                lastError = error
                do {
                    try await BoundedCaptureCall.run(
                        call: "stopCapture(start cleanup)", device: currentMicDeviceUID,
                        until: min(deadline, ContinuousClock.now + BoundedCaptureCall.stopLimit),
                        onAbandon: { [self] in invalidateOutputs() }
                    ) { try await reference.stream.stopCapture() }
                } catch is BoundedCaptureCall.TimedOut {
                    throw RecordingError.noAudioAtStart
                } catch {
                    throw RecordingError.failedToStart("\(lastError!.localizedDescription) Capture cleanup failed: \(error.localizedDescription)")
                }
                await drainSampleCallbacks()
                if attempt < 2 { try await Task.sleep(for: min(retryDelay, max(.zero, deadline - ContinuousClock.now))) }
            }
        }
        throw RecordingError.failedToStart(lastError?.localizedDescription ?? "Failed to start unified capture.")
    }

    func invalidateOutputs() {
        streamLock.withLock { retired = true }
        appHandler.invalidate()
        micHandler.invalidate()
    }

    private func stopAbandoned(_ reference: CaptureStreamReference) async {
        _ = try? await BoundedCaptureCall.run(
            call: "stopCapture(abandoned)", device: currentMicDeviceUID,
            until: ContinuousClock.now + BoundedCaptureCall.stopLimit,
            onAbandon: { [self] in invalidateOutputs() }
        ) { try await reference.stream.stopCapture() }
    }

    private static func makeConfiguration(micDeviceUID: String?, capturesAppAudio: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = capturesAppAudio
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = micDeviceUID
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = capturesAppAudio ? 1 : 2
        configuration.height = capturesAppAudio ? 1 : 2
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
    /// retained configuration is committed only after a successful response from the current stream.
    func retargetMic(deviceUID: String?) async -> Bool {
        guard !micSwitchTimedOut else { return false }
        guard let stream else {
            logger.warning(
                "Mic retarget requested with no running stream. deviceUID=\(deviceUID ?? "<default>", privacy: .public)"
            )
            return false
        }

        let update = configuration.copy() as! SCStreamConfiguration
        update.microphoneCaptureDeviceID = deviceUID
        let updateEnd = CaptureTrace.begin("streamUpdate", "device=\(deviceUID ?? "<default>")")
        do {
            let reference = CaptureStreamReference(stream: stream)
            let configurationReference = CaptureConfigurationReference(configuration: update)
            try await BoundedCaptureCall.run(
                call: "updateConfiguration", device: deviceUID,
                until: ContinuousClock.now + BoundedCaptureCall.switchLimit
            ) { try await reference.stream.updateConfiguration(configurationReference.configuration) }
            let accepted = streamLock.withLock {
                guard !retired, _stream === stream else { return false }
                configuredMicDeviceUID = deviceUID
                configuration.microphoneCaptureDeviceID = deviceUID
                return true
            }
            guard accepted else { return false }
            updateEnd("ok")
            logger.notice(
                "Mic retargeted on live stream. deviceUID=\(deviceUID ?? "<default>", privacy: .public)"
            )
            return true
        } catch {
            if error is BoundedCaptureCall.TimedOut { streamLock.withLock { switchTimedOut = true } }
            updateEnd("error \(error.localizedDescription)")
            logger.error(
                "Mic retarget failed; continuing on previous device. deviceUID=\(deviceUID ?? "<default>", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Test seam: attach an already-"started" stream without going through `start()`, which needs
    /// live `SCShareableContent`, a capturable window, and TCC grants.
    func attachStreamForTesting(_ stream: any UnifiedCaptureStreaming) {
        setStream(stream)
    }

    func stop() async {
        streamLock.withLock { retired = true }
        if let stream = takeStream() {
            let stopEnd = CaptureTrace.begin("streamStop")
            await stopAbandoned(CaptureStreamReference(stream: stream))
            stopEnd("done")
        }
        invalidateOutputs()
        await drainSampleCallbacks()
        appHandler.closeOutput()
        micHandler.closeOutput()
    }

    /// Stops the stream but leaves the output writers open, so the files stay open, no `.timing`
    /// sidecar is written, and the accumulated timing segments survive.
    ///
    /// Used by the mid-session restart, which replaces the stream and its handlers while the
    /// recording continues writing into the same files. Callers that are finishing a recording must
    /// use `stop()` instead — this deliberately leaves the writers unfinalized.
    func stopStreamPreservingOutput() async {
        streamLock.withLock { retired = true }
        if let stream = takeStream() {
            let stopEnd = CaptureTrace.begin("streamStop", "preservingOutput=true")
            await stopAbandoned(CaptureStreamReference(stream: stream))
            stopEnd("done")
        }
        invalidateOutputs()
        await drainSampleCallbacks()
    }

    /// Returns once every sample callback already queued has run.
    func drainSampleCallbacks() async {
        await withCheckedContinuation { continuation in
            appQueue.async { continuation.resume() }
        }
        await withCheckedContinuation { continuation in
            micQueue.async { continuation.resume() }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        handleStreamStopped(error)
    }

#if DEBUG
    /// Test seam: drive the stream-stopped path without an `SCStream`, which cannot be constructed
    /// in tests (it needs live `SCShareableContent`, a capturable window, and TCC grants).
    func handleStreamStoppedForTesting(_ error: any Error) {
        handleStreamStopped(error)
    }
#endif

    nonisolated private func handleStreamStopped(_ error: any Error) {
        guard streamLock.withLock({ !retired }) else { return }
        invalidateOutputs()
        logger.error("Unified capture stream stopped with error: \(error.localizedDescription, privacy: .public)")
        CaptureTrace.log("streamStoppedWithError", "error=\(error.localizedDescription)")
        // The stream is gone; stop reporting it as an active capture before anyone reacts to the
        // error and tries to use it.
        takeStream()
        if isTCCAccessDeniedError(error) {
            notificationCenter.post(
                name: .appAudioCaptureAccessDenied,
                object: nil,
                userInfo: ["errorDescription": error.localizedDescription]
            )
        }
        // Reported for every error, not just TCC: a filter losing its window and the capture
        // connection being interrupted both end the recording's audio just as completely.
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
