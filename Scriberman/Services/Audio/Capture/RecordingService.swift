import CoreAudio
import CoreGraphics
import Foundation
import OSLog
import SwiftData

private let recordingAudioObjectSystemObjectID = AudioObjectID(kAudioObjectSystemObject)

enum RecordingError: LocalizedError {
    case alreadyRecording
    case microphoneDenied
    case invalidWorkspaceAccess
    /// Capture stopped on its own during an active recording. `detail` carries the underlying
    /// cause (e.g. the `SCStream` error's description) for diagnostics only — it is deliberately
    /// kept out of `errorDescription`, whose wording is user-facing and unchanged.
    case captureInterrupted(detail: String?)
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress."
        case .microphoneDenied:
            return "Microphone access is denied. Enable it in System Settings."
        case .invalidWorkspaceAccess:
            return "Workspace is not currently writable."
        case .captureInterrupted:
            return "Recording stopped because audio capture was interrupted."
        case .failedToStart(let reason):
            return "Failed to start recording: \(reason)"
        }
    }

    /// The underlying cause, when one is known. Written to the session failure log so a failure
    /// records what actually happened rather than a generic reason. Not shown to the user.
    var diagnosticDetail: String? {
        switch self {
        case .captureInterrupted(let detail):
            return detail
        case .failedToStart(let reason):
            return reason
        case .alreadyRecording, .microphoneDenied, .invalidWorkspaceAccess:
            return nil
        }
    }
}

extension Notification.Name {
    static let appAudioCaptureAccessDenied = Notification.Name("appAudioCaptureAccessDenied")
}

/// The microphone capture is aimed at. `deviceUID` nil is the system default. `firstBufferHostTime`
/// is when the first buffer arrived after capture was aimed at it, nil until then.
struct MicCaptureTarget: Equatable, Sendable {
    let deviceUID: String?
    var firstBufferHostTime: HostNanoseconds?
}

/// A microphone that delivered audio, resolved when its first buffer arrived.
struct CapturedMicDevice: Equatable, Sendable {
    let uid: String
    let name: String
    /// True when capture was aimed at the system default, which was this device then.
    let isSystemDefault: Bool
}

/// The microphone a recording is capturing, as reported to the recording view and the API.
enum CapturedMicrophone: Equatable, Sendable {
    /// Capture delivers audio from this device.
    case capturing(CapturedMicDevice)
    /// Capture is moving to another device, or has not delivered audio from it yet.
    case switching
    /// The device is not known.
    case unknown
}

typealias SendableAudioObjectPropertyListenerBlock =
    @Sendable @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void

actor RecordingService: RecordingServiceProtocol {
    typealias PermissionChecker = @Sendable () async throws(RecordingError) -> Void
    typealias ScopedAccessStarter = @Sendable (URL) -> Bool
    typealias ScopedAccessStopper = @Sendable (URL) -> Void
    typealias ScreenCaptureSessionFactory = @Sendable () -> any ScreenCaptureSessionControlling
    typealias DefaultTagApplier = @Sendable (RecordingSession, ModelContext) throws -> Void
    typealias DateProvider = @Sendable () -> Date
    typealias HostTimeProvider = @Sendable () -> HostNanoseconds
    /// A capture session about to start its ScreenCaptureKit stream.
    enum CaptureSessionStart: Sendable {
        case unified(UnifiedCaptureSession)
    }

    /// Starts a capture session's stream. Injected so tests can start sessions on stub streams;
    /// the real start needs live `SCShareableContent` and TCC grants.
    typealias CaptureSessionStarter = @Sendable (CaptureSessionStart) async throws -> Void

    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let notificationCenter: NotificationCenter
    private let fileManager = FileManager.default
    private let mixdownCoordinator: any RecordingMixdownCoordinating
    private let finalizer: RecordingFinalizer
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingService")
    private let hardware: AudioDeviceHardwareProviding
    private let permissionChecker: PermissionChecker
    private let scopedAccessStarter: ScopedAccessStarter
    private let scopedAccessStopper: ScopedAccessStopper
    private let makeScreenCaptureSession: ScreenCaptureSessionFactory
    private let applyDefaultTag: DefaultTagApplier
    private let now: DateProvider
    /// The host clock that pauses and the stop are timed by.
    private let hostNow: HostTimeProvider
    private let startCaptureSession: CaptureSessionStarter
    private var recordingStartedAt: Date?
    private var recordingCreatedAt: Date?
    /// When the stop closed the pause clock.
    private var recordingStopRequestedAt: Date?
    private var recordingIdentifier: String?
    /// Chosen once at start and held until the recording is finalized.
    private var recordingFolderURL: URL?
    /// The flag values the current recording started with. Capture start, every capture restart,
    /// and finalization read these, never the stored flags.
    private var recordingAudioSyncFlags: AudioSyncFlags = .shippedDefaults
    private var currentSessionID: UUID?
    private var appAudioURL: URL?
    private var micStartHostTime: HostNanoseconds?
    private var appStartHostTime: HostNanoseconds?
    private var videoStartHostTime: HostNanoseconds?
    private var activeCaptureDisplayID: CGDirectDisplayID?
    /// The microphone the recording prefers. Kept while it is absent or refuses the route, so
    /// capture moves to it when it becomes usable.
    private var desiredMicDeviceUID: String?
    /// The device capture uses while the preferred one is not usable: the device the recording
    /// started on, or `nil` for the system default.
    private var fallbackMicDeviceUID: String?
    private var micFileURL: URL?
    private var hasScopedRecordingAccess = false
    private var recordingWorkspaceRootURL: URL?
    private var activeCapturedAppName: String?
    private var pendingTitle: String?
    private var unifiedCaptureSession: UnifiedCaptureSession?
    /// Retained so the start safety net can repeat a capture start with identical inputs.
    private var activeAppSource: UnifiedCaptureSession.AppSource?
    private var screenCaptureSession: (any ScreenCaptureSessionControlling)?
    private var shouldSkipScreenMux = false
    private var pendingError: RecordingError?
    /// Monotonic per-recording count of capture streams that stopped on their own. Read by
    /// the capture-health monitor as direct evidence of death, rather than inferred from
    /// stalled counters. Reset when a recording starts.
    private var captureStreamFailureCount = 0
    /// How many of `captureStreamFailureCount` a resume has dealt with by checking and restarting
    /// capture, so the capture-health monitor does not act on them again.
    private var handledStreamFailureCount = 0
    /// How many times capture was restarted mid-recording. Persisted onto the session at stop so
    /// an interrupted recording is discoverable when reviewed, not only in the log.
    private(set) var captureRestartCount = 0
#if DEBUG
    /// Overrides the write-failure total read at stop. Test seam only.
    private var writeFailureOverrideForTesting: Int?
#endif
    /// Advanced at each recording start. An operation that suspended compares it with the value it
    /// started with, so a late completion never acts on a later recording.
    private var recordingGeneration = 0
    /// When the microphone capture now running was started, by the host clock.
    private var micCaptureStartedAt: HostNanoseconds?
    /// The in-place capture restart in flight. A second request waits for it.
    private var restartInPlaceTask: Task<Bool, Never>?
    /// The resume in flight. Pause and resume requests made during it wait for it.
    private var resumeTask: Task<Bool, Never>?
    /// The last microphone transition queued: a capture target update, a unified capture restart
    /// restart. Each one waits for the one queued before it.
    private var micTransitionTail: Task<Void, Never>?
    /// Transitions queued and not finished, by number.
    private var micTransitionsInFlight: Set<Int> = []
    private var nextMicTransitionNumber = 0
    /// A capture target update queued and not started yet. A request made before it starts shares
    /// it, since it reads the target when it runs.
    private var queuedMicRetarget: Task<Void, Never>?
    /// Numbers every capture stream, so a callback from a replaced or stopped stream is told apart
    /// from one from the recording's current stream.
    private var nextCaptureStreamNumber = 0
    private var unifiedStreamNumber: Int?
    /// The removed microphone already logged, so a removal is logged once.
    private var loggedRemovedMicUID: String?
    /// True while the preferred microphone is absent, so its return is logged.
    private var isPreferredMicAbsent = false
    /// The microphone capture is aimed at, numbered so a late first-buffer notice for an earlier
    /// target is ignored.
    private var micTarget: MicCaptureTarget?
    private var micTargetNumber = 0
    /// The latest removal of the captured mic or switch to another device, for the capture-health
    /// grace period. Capture-health restarts are not transitions.
    private var lastMicTransition: CaptureHealthMonitor.MicTransition?
    private var micTransitionCount = 0
    /// The device the current target resolved to when its first buffer arrived.
    private var capturedMicDevice: CapturedMicDevice?
    /// True from a switch request until capture is aimed at a new target, or the switch failed
    /// and left capture where it was.
    private var isMicSwitchUnsettled = false
    /// The device last captured when the current pause began; reported until the pause ends.
    private var micDeviceCapturedAtPause: CapturedMicDevice?
    /// The device the unified stream's microphone UID resolved to when it was configured. A device
    /// that left and came back under the same UID gets a new id; the stream then delivers nothing
    /// until it is moved away and back (spec, test 4, steps 7 and 8).
    private var unifiedConfiguredMicDeviceID: AudioDeviceID?
    private var liveAudioClock: LiveCaptureClock?
    /// The recording's pause clock and source gates. Made once per recording, kept by every
    /// capture restart.
    private var captureGates = RecordingCaptureGates()
    private var liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation?
    // nonisolated(unsafe): initialized once and used for CoreAudio C callback registration/removal lifecycle.
    // @Sendable: the macOS 27 SDK takes the listener as `sending`; the block only captures a weak
    // reference to this actor and hops onto it, so sharing it with CoreAudio's queue is safe.
    nonisolated(unsafe) private var hardwarePropertyListener: SendableAudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var hasRegisteredHardwareListeners = false
    private let hardwareListenerQueue: DispatchQueue

    /// Where the service is in a recording's life. Each transition is written before the first
    /// `await` of the method that makes it, so concurrent callers see it straight away.
    private enum LifecycleState {
        case idle
        case starting
        case recording
        case stopping(Task<UUID?, Never>)
    }

    private var lifecycleState: LifecycleState = .idle
    private var isRecordingValue: Bool {
        if case .recording = lifecycleState {
            return true
        }
        return false
    }

    /// True while the recording that had `generation` is still running.
    private func isCurrentRecording(_ generation: Int) -> Bool {
        generation == recordingGeneration && isRecordingValue
    }

    /// True while the recording that had `generation` is starting or running.
    private func isCurrentOrStartingRecording(_ generation: Int) -> Bool {
        guard generation == recordingGeneration else { return false }
        switch lifecycleState {
        case .starting, .recording: return true
        case .idle, .stopping: return false
        }
    }

    private var audioLevelValue: Float = 0
#if DEBUG
    private var stopRecordingCallCount = 0
#endif

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        hardware: AudioDeviceHardwareProviding = CoreAudioDeviceHardware(),
        notificationCenter: NotificationCenter = .default,
        mixdownCoordinator: (any RecordingMixdownCoordinating)? = nil,
        screenVideoMuxer: (any ScreenVideoMuxing)? = nil,
        finalizer: RecordingFinalizer? = nil,
        permissionChecker: @escaping PermissionChecker = RecordingPermissionService.ensureRecordingPermissions,
        scopedAccessStarter: @escaping ScopedAccessStarter = { $0.startAccessingSecurityScopedResource() },
        scopedAccessStopper: @escaping ScopedAccessStopper = { $0.stopAccessingSecurityScopedResource() },
        screenCaptureSessionFactory: @escaping ScreenCaptureSessionFactory = { ScreenCaptureSession() },
        defaultTagApplier: @escaping DefaultTagApplier = { try TagService().applyDefaultTag(to: $0, in: $1) },
        now: @escaping DateProvider = { Date() },
        hostNow: @escaping HostTimeProvider = { HostNanoseconds(machTicks: mach_absolute_time()) },
        captureSessionStarter: @escaping CaptureSessionStarter = { start in
            switch start {
            case .unified(let session):
                try await session.start()
            }
        }
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.hardware = hardware
        self.notificationCenter = notificationCenter
        self.permissionChecker = permissionChecker
        self.scopedAccessStarter = scopedAccessStarter
        self.scopedAccessStopper = scopedAccessStopper
        self.makeScreenCaptureSession = screenCaptureSessionFactory
        self.applyDefaultTag = defaultTagApplier
        self.now = now
        self.hostNow = hostNow
        self.startCaptureSession = captureSessionStarter
        self.hardwareListenerQueue = DispatchQueue(label: "Scriberman.RecordingService.HardwareListeners")
        let mixdownCoordinator = mixdownCoordinator ?? RecordingMixdownCoordinator(
            workspaceService: workspaceService,
            modelContainer: modelContainer
        )
        self.mixdownCoordinator = mixdownCoordinator
        self.finalizer = finalizer ?? RecordingFinalizer(
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer ?? ScreenVideoMuxer(
                workspaceService: workspaceService,
                modelContainer: modelContainer
            )
        )
        self.hardwarePropertyListener = { [weak self] _, _ in
            Task {
                await self?.handleHardwareChange()
            }
        }

    }

    deinit {
        if hasRegisteredHardwareListeners,
           let hardwarePropertyListener {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = withUnsafePointer(to: &devicesAddress) { addressPointer in
                AudioObjectRemovePropertyListenerBlock(
                    recordingAudioObjectSystemObjectID,
                    addressPointer,
                    hardwareListenerQueue,
                    hardwarePropertyListener
                )
            }
            var defaultInputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = withUnsafePointer(to: &defaultInputAddress) { addressPointer in
                AudioObjectRemovePropertyListenerBlock(
                    recordingAudioObjectSystemObjectID,
                    addressPointer,
                    hardwareListenerQueue,
                    hardwarePropertyListener
                )
            }
        }
    }

    func isRecording() async -> Bool {
        isRecordingValue
    }

    #if DEBUG
    func stopRecordingCallCountForTesting() -> Int {
        stopRecordingCallCount
    }

    func setRecordingStateForTesting(
        isRecording: Bool,
        recordingIdentifier: String? = nil,
        recordingWorkspaceRootURL: URL? = nil,
        recordingCreatedAt: Date? = nil,
        recordingFolderURL: URL? = nil,
        pendingTitle: String? = nil,
        currentSessionID: UUID? = nil,
        screenCaptureSession: (any ScreenCaptureSessionControlling)? = nil,
        videoStartHostTime: HostNanoseconds? = nil,
        shouldSkipScreenMux: Bool = false,
        activeAppFileURL: URL? = nil,
        activeAppProcessID: pid_t? = nil,
        liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation? = nil
    ) {
        self.captureGates = RecordingCaptureGates(hostNow: hostNow)
        self.recordingGeneration += 1
        self.liveAudioContinuation = liveAudioContinuation
        self.activeAppSource = if let activeAppFileURL, let activeAppProcessID {
            UnifiedCaptureSession.AppSource(fileURL: activeAppFileURL, processID: activeAppProcessID)
        } else { nil }
        self.lifecycleState = isRecording ? .recording : .idle
        self.recordingIdentifier = recordingIdentifier
        self.recordingWorkspaceRootURL = recordingWorkspaceRootURL
        self.recordingCreatedAt = recordingCreatedAt
        self.recordingFolderURL = recordingFolderURL
        self.pendingTitle = pendingTitle
        self.currentSessionID = currentSessionID
        self.screenCaptureSession = screenCaptureSession
        self.videoStartHostTime = videoStartHostTime
        self.shouldSkipScreenMux = shouldSkipScreenMux
    }

    func setMicRecoveryStateForTesting(desiredMicDeviceUID: String?, micFileURL: URL?, fallbackMicDeviceUID: String? = nil) {
        self.desiredMicDeviceUID = desiredMicDeviceUID
        self.fallbackMicDeviceUID = fallbackMicDeviceUID
        self.micFileURL = micFileURL
    }

    func setCaptureRestartCountForTesting(_ count: Int) {
        captureRestartCount = count
    }

    /// Test seam: write failures originate inside `AudioFileStreamer`'s private queue, so a test
    /// cannot provoke them through the service.
    func setWriteFailureOverrideForTesting(_ count: Int?) {
        writeFailureOverrideForTesting = count
    }

    func setUnifiedCaptureSessionForTesting(_ session: UnifiedCaptureSession?) {
        self.unifiedCaptureSession = session
        self.unifiedConfiguredMicDeviceID = resolveDeviceID(for: session?.currentMicDeviceUID)
    }

    func simulateHardwareChangeForTesting() async {
        await handleHardwareChange()
    }

    func cleanupRecordingStateForTesting(deleteScreenTmpVideo: Bool = true) async {
        await cleanupRecordingState(deleteScreenTmpVideo: deleteScreenTmpVideo)
    }
    #endif

    func audioLevel() async -> Float {
        let levels = await audioLevels()
        return max(levels.mic, levels.app)
    }

    func activityTimestamps() async -> (mic: Date?, app: Date?) {
        (unifiedCaptureSession?.micLastActivityAt, appAudioURL == nil ? nil : unifiedCaptureSession?.appLastActivityAt)
    }

    /// Frames written per source since capture started, plus write failures.
    ///
    /// This is the signal the start safety net verifies against, deliberately in preference to
    /// `audioLevels()` or `activityTimestamps()`: frames are produced at the capture sample rate
    /// whether or not anyone is speaking, so a silent room reads as healthy. Levels and activity
    /// both require sound above a floor and would fail a recording that simply started quiet.
    ///
    /// App counts are absent for a microphone-only recording.
    func captureFrameCounts() async -> (mic: Int64?, app: Int64?, micWriteFailures: Int, appWriteFailures: Int) {
        (unifiedCaptureSession?.micFramesWritten ?? 0,
         appAudioURL == nil ? nil : unifiedCaptureSession?.appFramesWritten,
         unifiedCaptureSession?.micWriteFailureCount ?? 0,
         appAudioURL == nil ? 0 : unifiedCaptureSession?.appWriteFailureCount ?? 0)
    }

    func audioLevels() async -> (mic: Float, app: Float) {
        guard !isPaused() else { audioLevelValue = 0; return (0, 0) }
        let mic = unifiedCaptureSession?.micAudioLevel ?? 0
        let app = appAudioURL == nil ? 0 : unifiedCaptureSession?.appAudioLevel ?? 0
        audioLevelValue = max(mic, app)
        return (mic, app)
    }

    /// Records that a capture stream stopped on its own during an active recording.
    ///
    /// Before this existed, `stream(_:didStopWithError:)` terminated in a `logger.error` for every
    /// error that was not a TCC denial, so a dead stream left `isRecordingValue == true` and the
    /// recording appeared healthy for the rest of its duration. `pendingError` is the channel that
    /// carries the failure to the user interface and into the session failure log.
    func reportCaptureStreamFailure(_ error: any Error) {
        guard isRecordingValue else {
            return
        }
        let detail = error.localizedDescription
        logger.error("Capture stream stopped during an active recording: \(detail, privacy: .public)")
        pendingError = .captureInterrupted(detail: detail)
        captureStreamFailureCount += 1
    }

    /// Records a failure reported by stream `streamNumber`. A callback from a stream that was
    /// replaced or stopped is ignored, so it is never counted against the current capture.
    func reportCaptureStreamFailure(_ error: any Error, fromStream streamNumber: Int) {
        guard isRecordingValue, streamNumber == unifiedStreamNumber else {
            logger.notice(
                "Ignored a stale capture stream callback: stream=\(streamNumber, privacy: .public) currentUnified=\(self.unifiedStreamNumber.map(String.init) ?? "none", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return
        }
        reportCaptureStreamFailure(error)
    }

    /// Numbers a new capture stream and routes its failures, tagged with that number, to
    /// `reportCaptureStreamFailure(_:fromStream:)`.
    private func reportStreamFailures(of session: UnifiedCaptureSession) -> Int {
        nextCaptureStreamNumber += 1
        let streamNumber = nextCaptureStreamNumber
        session.onStreamStopped = { [weak self] error in
            Task { [weak self] in await self?.reportCaptureStreamFailure(error, fromStream: streamNumber) }
        }
        return streamNumber
    }

    func captureHealthSnapshot() async -> CaptureHealthMonitor.Snapshot {
        let counts = await captureFrameCounts()
        var snapshot = CaptureHealthMonitor.Snapshot(
            micFrames: counts.mic,
            appFrames: counts.app,
            streamFailureCount: captureStreamFailureCount,
            handledStreamFailureCount: handledStreamFailureCount
        )
        snapshot.lastMicTransition = lastMicTransition
        snapshot.micWriteFailures = counts.micWriteFailures
        snapshot.appWriteFailures = counts.appWriteFailures
        return snapshot
    }

    private func startAudioCapture(micFileURL: URL, appFileURL: URL?, appProcessID: pid_t?) async throws {
        let target = micCaptureTargetUID()
        let deviceID = resolveDeviceID(for: target) ?? hardware.defaultInputDeviceID()
        guard let deviceID, hardware.isUsableMicrophone(deviceID: deviceID) else {
            throw RecordingError.failedToStart("No usable microphone")
        }
        CaptureTrace.armFirstBuffer(target: target ?? "<default>")
        let unified = UnifiedCaptureSession(
            micFileURL: micFileURL, appFileURL: appFileURL, processID: appProcessID,
            micDeviceUID: target, liveAudioContinuation: liveAudioContinuation,
            onMicFirstHostTime: { [weak self, clock = liveAudioClock] hostTime in
                clock?.observe(hostTime)
                Task { await self?.captureMicStartHostTimeIfNeeded(hostTime) }
            },
            onAppFirstHostTime: { [weak self, clock = liveAudioClock] hostTime in
                clock?.observe(hostTime)
                Task { await self?.captureAppStartHostTimeIfNeeded(hostTime) }
            }, gates: captureGates
        )
        let number = reportStreamFailures(of: unified)
        unifiedStreamNumber = number
        do {
            try await startCaptureSession(.unified(unified))
        } catch {
            await unified.stop()
            if unifiedStreamNumber == number { unifiedStreamNumber = nil }
            throw error
        }
        unifiedCaptureSession = unified
        unifiedConfiguredMicDeviceID = resolveDeviceID(for: target)
        appAudioURL = appFileURL
        micCaptureStartedAt = hostNow()
        publishMicTarget(target)
    }

    /// Tears audio capture down and starts it again with the same configuration and the same
    /// files, leaving the session, its folder, and screen capture untouched.
    ///
    /// Used by the start safety net when verification finds that nothing is being written.
    /// Overwriting the existing audio files is safe for exactly one reason: this runs only when
    /// zero frames were written, so there is nothing to lose. Any future caller that restarts
    /// after a partial failure must revisit that.
    func restartAudioCapture() async -> Bool {
        guard isRecordingValue, let micFileURL else {
            return false
        }

        // This path overwrites the audio files, which is safe only because it runs when nothing has
        // been written. Once frames exist, overwriting destroys the recording it was meant to save;
        // `restartAudioCaptureInPlace()` is the caller for that case.
        let counts = await captureFrameCounts()
        let framesWritten = (counts.mic ?? 0) + (counts.app ?? 0)
        guard framesWritten == 0 else {
            logger.error(
                "Start-path restart refused: \(framesWritten, privacy: .public) frames already written. Mid-session recovery must use restartAudioCaptureInPlace()."
            )
            return false
        }

        await stopAudioCaptureForRestart()

        // Re-anchor: the previous attempt contributed no samples, so the timeline reference must
        // come from the new one.
        micStartHostTime = nil
        appStartHostTime = nil

        do {
            try await startAudioCapture(
                micFileURL: micFileURL,
                appFileURL: activeAppSource?.fileURL,
                appProcessID: activeAppSource?.processID
            )
            logger.notice("Audio capture restarted after failed start verification.")
            return true
        } catch {
            logger.error(
                "Audio capture restart failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Restarts capture mid-recording, preserving every frame already captured.
    ///
    /// Distinct from `restartAudioCapture()` in the one way that matters: it does not touch the
    /// writers. The `SCStream` and its output handlers are replaced, but the same
    /// `AudioFileStreamer` instances carry over, so the files stay open, their accumulated timing
    /// segments survive, and no `.timing` sidecar is written early.
    ///
    /// The timeline anchors are deliberately left in place. `captureMicStartHostTimeIfNeeded`
    /// guards on nil, so the new handlers' first buffers do not re-anchor the recording — audio
    /// captured after the restart lands at its true position against the reference established at
    /// start, and the dead interval reads as silence of its real duration rather than a splice.
    ///
    /// A request made while a restart runs waits for that restart and gets its result.
    func restartAudioCaptureInPlace() async -> Bool {
        if let restartInPlaceTask {
            return await restartInPlaceTask.value
        }
        guard isRecordingValue else { return false }
        let task = enqueueMicTransition { [weak self] in await self?.performRestartInPlace() ?? false }
        restartInPlaceTask = task
        let restarted = await task.value
        if restartInPlaceTask == task {
            restartInPlaceTask = nil
        }
        return restarted
    }

    private func performRestartInPlace() async -> Bool {
        let generation = recordingGeneration
        guard isCurrentRecording(generation), let micFileURL else {
            return false
        }

        guard let existing = unifiedCaptureSession else { return false }
        let startedAt = Date()
        let framesBefore = (mic: existing.micFramesWritten, app: existing.appFramesWritten)
        await existing.stopStreamPreservingOutput()
        guard isCurrentRecording(generation), unifiedCaptureSession === existing else {
            return false
        }
        Self.sendStartedPauseMarkers(gates: captureGates, to: liveAudioContinuation, mic: true, app: appAudioURL != nil)
        let reused = existing.streamers
        let targetUID = micCaptureTargetUID()
        noteMicSwitchRequested(path: "unified", target: targetUID, reason: .restart)

        let replacement = UnifiedCaptureSession(
            micFileURL: micFileURL,
            appFileURL: activeAppSource?.fileURL,
            processID: activeAppSource?.processID,
            micDeviceUID: targetUID,
            liveAudioContinuation: liveAudioContinuation,
            onMicFirstHostTime: { [weak self, clock = liveAudioClock] hostTime in
                clock?.observe(hostTime)
                Task { [weak self] in await self?.captureMicStartHostTimeIfNeeded(hostTime) }
            },
            onAppFirstHostTime: { [weak self, clock = liveAudioClock] hostTime in
                clock?.observe(hostTime)
                Task { [weak self] in await self?.captureAppStartHostTimeIfNeeded(hostTime) }
            },
            reusingStreamers: reused,
            preparedStreamers: existing.preparedStreamers,
            gates: captureGates
        )
        let streamNumber = reportStreamFailures(of: replacement)

        do {
            try await startCaptureSession(.unified(replacement))
        } catch {
            logger.error(
                "Mid-session capture restart failed: \(error.localizedDescription, privacy: .public). Captured audio is retained."
            )
            return false
        }
        // The recording stopped, or another restart replaced the session, while this one started.
        guard isCurrentRecording(generation), unifiedCaptureSession === existing else {
            logger.notice("Mid-session capture restart finished after the recording moved on; stopping its stream.")
            await replacement.stopStreamPreservingOutput()
            return false
        }

        unifiedCaptureSession = replacement
        unifiedStreamNumber = streamNumber
        unifiedConfiguredMicDeviceID = resolveDeviceID(for: targetUID)
        micCaptureStartedAt = hostNow()
        publishMicTarget(targetUID)
        captureRestartCount += 1
        let elapsedMs = Date().timeIntervalSince(startedAt) * 1_000
        logger.notice(
            "Capture restarted mid-session (restart #\(self.captureRestartCount, privacy: .public)). teardownAndStartMs=\(elapsedMs, privacy: .public) micFramesBefore=\(framesBefore.mic, privacy: .public) appFramesBefore=\(framesBefore.app, privacy: .public). The outage appears as silence in the timing sidecar gap."
        )
        return true
    }

    private func stopAudioCaptureForRestart() async {
        await unifiedCaptureSession?.stop()
        unifiedCaptureSession = nil
        unifiedStreamNumber = nil
        appAudioURL = nil
    }

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID? = nil,
        preferredMicDeviceUID: String? = nil,
        captureDisplayID: CGDirectDisplayID? = nil,
        capturedAppName: String? = nil,
        appProcessID: pid_t? = nil,
        title: String? = nil,
        liveAudioContinuation: AsyncStream<LiveAudioChunk>.Continuation? = nil,
        liveAudioClock: LiveCaptureClock? = nil,
        audioSyncFlags: AudioSyncFlags = .shippedDefaults
    ) async throws(RecordingError) -> UUID {
        guard case .idle = lifecycleState else {
            liveAudioContinuation?.finish()
            throw RecordingError.alreadyRecording
        }
        CaptureTrace.beginRecording("micOnly=\(appProcessID == nil)")
        lifecycleState = .starting
        recordingGeneration += 1
        self.captureGates = RecordingCaptureGates(hostNow: hostNow)
        self.liveAudioClock = liveAudioClock
        self.liveAudioContinuation = liveAudioContinuation
        var didStart = false
        defer {
            if !didStart {
                self.liveAudioContinuation?.finish()
                self.liveAudioContinuation = nil
            }
        }

        do {
            _ = try await workspaceService.requireAuthorizedWorkspace()
        } catch {
            lifecycleState = .idle
            throw RecordingError.invalidWorkspaceAccess
        }
        do {
            try await permissionChecker()
        } catch {
            lifecycleState = .idle
            throw RecordingError.failedToStart(error.diagnosticDetail ?? error.localizedDescription)
        }

        if !scopedAccessStarter(workspace.rootURL) {
            lifecycleState = .idle
            throw RecordingError.invalidWorkspaceAccess
        }

        hasScopedRecordingAccess = true
        recordingWorkspaceRootURL = workspace.rootURL

        do {
            let recordingCreatedAt = now()
            let recordingIdentifier = UUID().uuidString
            let recordingFolderURL = try RecordingFileLayout.createRecordingFolder(
                in: workspace,
                createdAt: recordingCreatedAt,
                fileManager: fileManager
            )
            self.recordingFolderURL = recordingFolderURL

            let fileURLs = RecordingFileLayout.recordingFileURLs(in: recordingFolderURL)
            let micFileURL = fileURLs.mic
            let appFileURL = fileURLs.app
            let screenTmpVideoURL = RecordingFileLayout.screenTmpVideoURL(in: recordingFolderURL)
            self.micStartHostTime = nil
            self.appStartHostTime = nil
            self.videoStartHostTime = nil
            self.activeCaptureDisplayID = captureDisplayID
            self.shouldSkipScreenMux = false
            self.micFileURL = micFileURL
            if let micDeviceID, micDeviceID != 0 {
                fallbackMicDeviceUID = hardware.deviceUID(deviceID: micDeviceID)
            } else {
                fallbackMicDeviceUID = nil
            }
            desiredMicDeviceUID = preferredMicDeviceUID ?? fallbackMicDeviceUID
            isPreferredMicAbsent = desiredMicDeviceUID != nil && resolveDeviceID(for: desiredMicDeviceUID) == nil
            self.activeAppSource = appProcessID.map {
                UnifiedCaptureSession.AppSource(fileURL: appFileURL, processID: $0)
            }
            self.recordingAudioSyncFlags = audioSyncFlags
            try await startAudioCapture(
                micFileURL: micFileURL,
                appFileURL: activeAppSource?.fileURL,
                appProcessID: appProcessID
            )
            self.recordingStartedAt = now()
            self.recordingStopRequestedAt = nil
            self.recordingCreatedAt = recordingCreatedAt
            self.recordingIdentifier = recordingIdentifier
            self.lifecycleState = .recording
            self.audioLevelValue = 0
            self.pendingError = nil
            self.captureStreamFailureCount = 0
            self.handledStreamFailureCount = 0
            self.captureRestartCount = 0
            self.activeCapturedAppName = activeAppSource == nil ? nil : capturedAppName
            self.pendingTitle = title

            if let captureDisplayID {
                let screenCaptureSession = makeScreenCaptureSession()
                screenCaptureSession.onError = { [weak self] _ in
                    Task { [weak self] in
                        await self?.handleScreenCaptureError()
                    }
                }
                do {
                    try await screenCaptureSession.start(
                        displayID: captureDisplayID,
                        videoURL: screenTmpVideoURL,
                        pauseClock: captureGates.clock
                    )
                    self.screenCaptureSession = screenCaptureSession
                    // A pause taken while the stream started was not reported to it.
                    if captureGates.clock.isPaused {
                        screenCaptureSession.recordingDidPause()
                    }
                } catch {
                    logger.warning(
                        "Screen capture failed to start; continuing without video. error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.screenCaptureSession = nil
                }
            } else {
                self.screenCaptureSession = nil
            }

            let session = RecordingSession(
                createdAt: recordingCreatedAt,
                duration: 0,
                micAudioURL: micFileURL.path,
                appAudioURL: appProcessID != nil ? appFileURL.path : nil,
                title: title ?? makeSessionTitle(createdAt: recordingCreatedAt),
                capturedAppName: activeCapturedAppName,
                status: .recording
            )
            // Saved with the session so recovery finalizes with the values the recording started with.
            session.audioSyncFlags = audioSyncFlags
            let context = ModelContext(modelContainer)
            context.insert(session)
            // Applied here so the recording satisfies the one-to-three tag bound from the moment it
            // exists, rather than from the moment it is first displayed or first tagged.
            try applyDefaultTag(session, context)
            try context.save()
            self.currentSessionID = session.id
            logger.notice(
                "Recording \(session.id, privacy: .public) audio-sync flags: timelineMixdown=\(audioSyncFlags.isTimelineMixdownEnabled, privacy: .public) captureHealthRecovery=\(audioSyncFlags.isCaptureHealthRecoveryEnabled, privacy: .public) unifiedStarted=\(self.unifiedCaptureSession != nil, privacy: .public)"
            )
            registerMicHardwareListeners()
            didStart = true
            // A device removed or returned while capture started is not seen by the listeners,
            // which start only now.
            await requestMicRetarget(reason: .start)
            return session.id
        } catch {
            await cleanupRecordingState()
            releaseRecordingScopeIfNeeded()
            audioLevelValue = 0
            lifecycleState = .idle
            throw RecordingError.failedToStart(error.localizedDescription)
        }
    }

    /// Stops the active recording. A call that arrives while a stop is in progress waits for that
    /// stop and returns its result, so teardown and finalization run once per recording.
    func stopRecording() async -> UUID? {
#if DEBUG
        stopRecordingCallCount += 1
#endif
        switch lifecycleState {
        case .idle, .starting:
            liveAudioContinuation?.finish()
            liveAudioContinuation = nil
            return nil
        case .stopping(let teardown):
            return await teardown.value
        case .recording:
            // Closed before the first suspension, so nothing captured from here on is admitted
            // while the capture queues drain.
            recordingStopRequestedAt = now()
            captureGates.clock.close(at: hostNow)
            let teardown = Task { await self.finalizeActiveRecording() }
            lifecycleState = .stopping(teardown)
            return await teardown.value
        }
    }

    private func finalizeActiveRecording() async -> UUID? {
        defer {
            audioLevelValue = 0
            lifecycleState = .idle
            releaseRecordingScopeIfNeeded()
        }

        // Read before teardown: these counters live on the capture sessions, which are released
        // immediately below. Zero app frames for the whole recording means app audio never
        // arrived, and the recording is finalized as microphone-only.
        let appFramesAtStop = appAudioURL == nil ? nil : unifiedCaptureSession?.appFramesWritten
        let micFramesAtStop = unifiedCaptureSession?.micFramesWritten
        // Write failures are read here for the same reason: the counters live on the capture
        // sessions, which are released below.
        var writeFailuresAtStop = (unifiedCaptureSession?.micWriteFailureCount ?? 0) + (unifiedCaptureSession?.appWriteFailureCount ?? 0)
#if DEBUG
        if let writeFailureOverrideForTesting {
            writeFailuresAtStop = writeFailureOverrideForTesting
        }
#endif
        if writeFailuresAtStop > 0 {
            logger.warning(
                "Recording finished with \(writeFailuresAtStop, privacy: .public) audio write failure(s). Captured audio is intact; the failed intervals are silence."
            )
        }

        deregisterMicHardwareListeners()
        await unifiedCaptureSession?.stop()
        unifiedCaptureSession = nil
        let activeScreenCaptureSession = screenCaptureSession
        screenCaptureSession = nil
        await activeScreenCaptureSession?.stop()
        captureVideoStartHostTimeIfNeeded(activeScreenCaptureSession?.videoStartHostTime)

        Self.sendStartedPauseMarkers(
            gates: captureGates, to: liveAudioContinuation, mic: true, app: appAudioURL != nil
        )
        liveAudioContinuation?.finish()
        liveAudioContinuation = nil

        let stoppedAt = now()
        let startedAt = recordingStartedAt ?? recordingCreatedAt ?? stoppedAt
        let duration = savedDuration(from: startedAt, to: stoppedAt)

        guard recordingIdentifier != nil, let recordingFolderURL, let sessionID = currentSessionID else {
            await cleanupRecordingState()
            return nil
        }

        let captureFileURLs = RecordingFileLayout.recordingFileURLs(in: recordingFolderURL)

        guard fileManager.fileExists(atPath: captureFileURLs.mic.path) else {
            await cleanupRecordingState()
            return nil
        }
        // An app source that wrote nothing is dropped here rather than carried into mixdown. Left
        // in place it produces no timing sidecar, which makes the timeline mix decline and fall
        // back to the constant-offset path, which sums a silent app source into the mic instead of
        // writing the mic-only mixdown.
        let appAudioMissing = RecordingStartVerifier.shouldFinalizeWithoutAppAudio(appFrames: appFramesAtStop)
        // Coverage is measured against the recording's duration, so a source that stopped partway
        // is reported even though it produced real audio. Zero coverage is the limiting case, and
        // `appAudioMissing` above still owns what happens there.
        var partiallyCoveredSources: [String] = []
        if RecordingStartVerifier.isSourcePartiallyCovered(frames: micFramesAtStop, duration: duration) {
            partiallyCoveredSources.append("mic")
        }
        if !appAudioMissing,
           RecordingStartVerifier.isSourcePartiallyCovered(frames: appFramesAtStop, duration: duration) {
            partiallyCoveredSources.append("app")
        }
        if !partiallyCoveredSources.isEmpty {
            logger.warning(
                "Recording finished with partially covered source(s): \(partiallyCoveredSources.joined(separator: ", "), privacy: .public). Audio is intact; the uncovered intervals are silence."
            )
        }
        let appProducedAudio = appFramesAtStop != nil && !appAudioMissing
        if appAudioMissing {
            logger.notice(
                "App audio produced no frames for the whole recording; finalizing as mic-only."
            )
        }
        let finalRecordingURLs: (mic: URL, app: URL?) = (
            captureFileURLs.mic,
            appProducedAudio && fileManager.fileExists(atPath: captureFileURLs.app.path)
                ? captureFileURLs.app
                : nil
        )
        let screenTmpVideoURL = RecordingFileLayout.screenTmpVideoURL(in: recordingFolderURL)
        let finalScreenVideoURL = RecordingFileLayout.screenVideoURL(in: recordingFolderURL)

        logger.info(
            "Prepared recording session folder. mic=\(finalRecordingURLs.mic.path, privacy: .public) app=\(finalRecordingURLs.app?.path ?? "nil", privacy: .public)"
        )

        do {
            let micStartHostTime = self.micStartHostTime ?? self.appStartHostTime ?? HostNanoseconds(nanoseconds: 0)
            let appStartHostTime = self.appStartHostTime
            let videoStartHostTime = shouldSkipScreenMux ? nil : self.videoStartHostTime
            let mixdownURL = finalRecordingURLs.mic.deletingLastPathComponent().appendingPathComponent("recording.m4a")
            let shouldRunScreenMux = videoStartHostTime != nil && fileManager.fileExists(atPath: screenTmpVideoURL.path)
            let audioAnchorHostTime = Self.audioAnchorHostTime(mic: micStartHostTime, app: appStartHostTime)

            if self.micStartHostTime == nil {
                logger.warning("Mic start host time missing for session \(sessionID, privacy: .public); using fallback for mixdown alignment.")
            }
            logger.info(
                "Scheduling mixdown for session \(sessionID, privacy: .public). micStart=\(micStartHostTime, privacy: .public) appStart=\(appStartHostTime?.description ?? "0", privacy: .public) hasApp=\(finalRecordingURLs.app != nil, privacy: .public)"
            )

            let context = ModelContext(modelContainer)
            guard let session = try? RecordingSession.fetch(id: sessionID, in: context) else {
                await cleanupRecordingState()
                return nil
            }
            session.duration = duration
            session.micAudioURL = finalRecordingURLs.mic.path
            session.appAudioURL = finalRecordingURLs.app?.path
            session.appAudioMissing = appAudioMissing ? true : nil
            session.captureInterruptionCount = captureRestartCount > 0 ? captureRestartCount : nil
            session.captureWriteFailureCount = writeFailuresAtStop > 0 ? writeFailuresAtStop : nil
            session.partiallyCoveredSources = partiallyCoveredSources.isEmpty ? nil : partiallyCoveredSources
            session.status = .recorded
            // Saved before the mux runs so recovery can retry it after a quit (design D3).
            if shouldRunScreenMux, let videoStartHostTime {
                session.screenMuxState = ScreenMuxState.pending.rawValue
                session.videoStartHostTimeNanos = Int64(clamping: videoStartHostTime.nanoseconds)
                session.audioAnchorHostTimeNanos = Int64(clamping: audioAnchorHostTime.nanoseconds)
            }
            if activeCaptureDisplayID != nil && !shouldRunScreenMux {
                session.screenCaptureWarning = "Screen recording failed — the display may have been off, disconnected, or not capturable."
                logger.warning(
                    "Screen capture was requested but produced no video. displayID=\(self.activeCaptureDisplayID ?? 0, privacy: .public) shouldSkipScreenMux=\(self.shouldSkipScreenMux, privacy: .public) videoStartHostTime=\(self.videoStartHostTime != nil ? "set" : "nil", privacy: .public)"
                )
            }
            try context.save()

            // Release capture writer resources before background mixdown starts.
            await cleanupRecordingState(deleteScreenTmpVideo: !shouldRunScreenMux)

            // Timeline path: mux the drift-corrected mixdown audio into the video. Legacy path:
            // mux the raw mic/app tracks, which the finalizer keeps until the mux has finished.
            var screenMux: ScreenVideoMuxRequest?
            if shouldRunScreenMux, let videoStartHostTime {
                let timelineEnabled = recordingAudioSyncFlags.isTimelineMixdownEnabled
                screenMux = ScreenVideoMuxRequest(
                    sessionID: sessionID,
                    screenTmpURL: screenTmpVideoURL,
                    screenVideoURL: finalScreenVideoURL,
                    micURL: finalRecordingURLs.mic,
                    appURL: finalRecordingURLs.app,
                    micStartHostTime: micStartHostTime,
                    appStartHostTime: appStartHostTime,
                    videoStartHostTime: videoStartHostTime,
                    timelineAudioURL: timelineEnabled ? mixdownURL : nil,
                    audioAnchorHostTime: timelineEnabled ? audioAnchorHostTime : nil
                )
            }
            await finalizer.schedule(RecordingFinalizationJob(
                sessionID: sessionID,
                micURL: finalRecordingURLs.mic,
                appURL: finalRecordingURLs.app,
                mixdownURL: mixdownURL,
                micStartHostTime: micStartHostTime,
                appStartHostTime: appStartHostTime,
                timelineMixdown: recordingAudioSyncFlags.isTimelineMixdownEnabled,
                screenMux: screenMux
            ))

            return sessionID
        } catch {
            await cleanupRecordingState()
            return nil
        }
    }

    /// Wall time minus pauses. A recording with pauses ends when its clock closed, so that
    /// teardown does not count as recorded time after a pause it stopped in.
    private func savedDuration(from startedAt: Date, to stoppedAt: Date) -> TimeInterval {
        let timeline = captureGates.clock.timeline
        guard timeline.hasPauses else {
            return max(0, stoppedAt.timeIntervalSince(startedAt))
        }
        let wall = (recordingStopRequestedAt ?? stoppedAt).timeIntervalSince(startedAt)
        return max(0, wall - timeline.pausedSeconds(until: hostNow()))
    }

    // MARK: - Pause and resume

    /// Pauses the active recording. Capture streams stay open and what they deliver is discarded.
    /// True when the recording is paused, including when it already was.
    ///
    /// A pause asked for during a resume waits for it. It still pauses when the resume failed, since
    /// the recording then stayed paused.
    func pauseRecording() async -> Bool {
        if let resumeTask {
            _ = await resumeTask.value
        }
        guard isRecordingValue else { return false }
        if captureGates.clock.pause(at: hostNow) {
            micDeviceCapturedAtPause = capturedMicDevice
            screenCaptureSession?.recordingDidPause()
        }
        return true
    }

    /// Ends the pause. True when the recording is running, including when it was not paused.
    ///
    /// Sources that died during the pause are restarted first, whatever the capture-health recovery
    /// flag is. If capture can't be restarted, resume fails and the recording stays paused.
    /// A request made during a resume waits for it and gets its result.
    func resumeRecording() async -> Bool {
        if let resumeTask {
            return await resumeTask.value
        }
        guard isRecordingValue else { return false }
        guard captureGates.clock.isPaused else { return true }
        let task = Task { await self.performResume() }
        resumeTask = task
        let resumed = await task.value
        if resumeTask == task {
            resumeTask = nil
        }
        return resumed
    }

    private func performResume() async -> Bool {
        let generation = recordingGeneration
        // A microphone switch still running, or requested while this resume restarts capture,
        // finishes before the clocks reopen. One that failed makes the microphone count as dead.
        repeat {
            await waitForMicTransitions()
            guard await restartDeadMicrophone(generation: generation), isCurrentRecording(generation) else {
                logger.error("Resume failed: microphone capture could not be restarted. The recording stays paused.")
                return false
            }
            guard isCurrentRecording(generation) else { return false }
        } while !micTransitionsInFlight.isEmpty
        acknowledgeStreamFailuresHandledByResume()
        guard captureGates.clock.resume(at: hostNow) else { return true }
        screenCaptureSession?.recordingDidResume()
        // A source that delivered nothing past the pause start has not marked it yet. Callbacks
        // already queued go first, so the marker follows any audio they still carry.
        // A pause that starts during the wait is not this one: the queues may still hold audio
        // from before it.
        let gates = captureGates
        let continuation = liveAudioContinuation
        let includesApp = appAudioURL != nil
        let endedPause = gates.clock.timeline.pauseStarts.count
        await unifiedCaptureSession?.drainSampleCallbacks()
        Self.sendStartedPauseMarkers(
            gates: gates, to: continuation, mic: true, app: includesApp, through: endedPause
        )
        return true
    }

    /// Every stream failure reported so far was checked by this resume and capture restarted.
    /// Its error is spent with it.
    private func acknowledgeStreamFailuresHandledByResume() {
        guard captureStreamFailureCount > handledStreamFailureCount else { return }
        handledStreamFailureCount = captureStreamFailureCount
        if case .captureInterrupted = pendingError {
            pendingError = nil
        }
    }

    /// Restarts microphone capture if it died during the pause. False when it is dead and could not
    /// be restarted.
    ///
    /// Restarts a stopped or stalled microphone before reopening the pause clock.
    private func restartDeadMicrophone(generation: Int) async -> Bool {
        if let unified = unifiedCaptureSession {
            let streamStopped = !unified.isStreamLive
            let stalled = isMicrophoneStalled()
            let switchFailed = unifiedMicNeedsSwitch(unified)
            guard streamStopped || stalled || switchFailed else { return true }
            logger.notice(
                "Resume restarting unified capture. streamStopped=\(streamStopped, privacy: .public) micStalled=\(stalled, privacy: .public) micSwitchFailed=\(switchFailed, privacy: .public)"
            )
            return await restartAudioCaptureInPlace()
        }
        return false
    }

    private func isMicrophoneStalled() -> Bool {
        guard let lastSign = [captureGates.mic.lastArrivalHostTime, micCaptureStartedAt].compactMap({ $0 }).max() else {
            return false
        }
        let now = hostNow().nanoseconds
        guard now > lastSign.nanoseconds else { return false }
        let silentSeconds = Double(now - lastSign.nanoseconds) / 1_000_000_000
        return silentSeconds > CaptureHealthMonitor.Configuration.default.stallThreshold
    }

    private static func sendStartedPauseMarkers(
        gates: RecordingCaptureGates,
        to continuation: AsyncStream<LiveAudioChunk>.Continuation?,
        mic: Bool,
        app: Bool,
        through limit: Int = .max
    ) {
        guard let continuation else { return }
        if mic {
            gates.mic.sendStartedPauseMarkers(through: limit) { continuation.yield(.pauseMarker($0, source: .mic)) }
        }
        if app {
            gates.app.sendStartedPauseMarkers(through: limit) { continuation.yield(.pauseMarker($0, source: .app)) }
        }
    }

    /// True while a recording is paused. `isRecording()` stays true.
    func isPaused() -> Bool {
        isRecordingValue && captureGates.clock.isPaused
    }

    /// Raw buffers each source has delivered during this recording, paused ones included. `app` is
    /// nil when app audio is not captured.
    func captureArrivalCounts() -> (mic: Int64, app: Int64?) {
        (captureGates.mic.arrivalCount, appAudioURL == nil ? nil : captureGates.app.arrivalCount)
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }

    func isScreenCaptureActive() async -> Bool {
        screenCaptureSession != nil
    }

    func retargetMic(desiredDeviceUID: String?) async {
        guard isRecordingValue else {
            return
        }
        self.desiredMicDeviceUID = desiredDeviceUID
        await requestMicRetarget(reason: .retarget)
    }

    // MARK: - Microphone transitions

    /// Why a microphone switch was requested. Logged only.
    private enum MicSwitchReason: String {
        case start, retarget, removal, preferredReturned, returnedUnderSameUID, hardwareChange
        case restart, resume
    }

    /// Queues `body` behind every microphone transition queued before it, so target updates,
    /// unified restarts run one at a time in request order.
    private func enqueueMicTransition<T: Sendable>(
        _ body: @escaping @Sendable () async -> T
    ) -> Task<T, Never> {
        nextMicTransitionNumber += 1
        let number = nextMicTransitionNumber
        micTransitionsInFlight.insert(number)
        let previous = micTransitionTail
        let task = Task { () -> T in
            await previous?.value
            let result = await body()
            self.micTransitionsInFlight.remove(number)
            return result
        }
        micTransitionTail = Task { _ = await task.value }
        return task
    }

    /// Returns once no microphone transition is queued or running.
    private func waitForMicTransitions() async {
        while !micTransitionsInFlight.isEmpty, let tail = micTransitionTail {
            await tail.value
        }
    }

    /// Moves capture to the target rule's device, after every transition queued before. A request
    /// made before a queued update starts shares that update.
    private func requestMicRetarget(reason: MicSwitchReason) async {
        if let queuedMicRetarget {
            await queuedMicRetarget.value
            return
        }
        let generation = recordingGeneration
        let task = enqueueMicTransition { [weak self] () -> Void in
            await self?.performMicRetarget(generation: generation, reason: reason)
        }
        queuedMicRetarget = task
        await task.value
    }

    private func performMicRetarget(generation: Int, reason: MicSwitchReason) async {
        queuedMicRetarget = nil
        guard isCurrentRecording(generation) else { return }
        if unifiedCaptureSession != nil {
            await applyMicTargetToUnifiedCapture(generation: generation, reason: reason)
            return
        }
    }

    /// True when the unified stream is not on the target rule's device, or is on a device that
    /// left and came back under the same UID.
    private func unifiedMicNeedsSwitch(_ session: UnifiedCaptureSession) -> Bool {
        session.currentMicDeviceUID != micCaptureTargetUID() || configuredMicDeviceReturned(session)
    }

    private func configuredMicDeviceReturned(_ session: UnifiedCaptureSession) -> Bool {
        guard let configured = session.currentMicDeviceUID else { return false }
        return resolveDeviceID(for: configured) != unifiedConfiguredMicDeviceID
    }

    /// Moves the unified stream's microphone to the capture target by updating the running stream,
    /// without a restart. The target is read again after every update, so a newer target is
    /// applied after an older one and an update that is no longer current is not published.
    ///
    /// When the configured device left and came back under the same UID, the stream is moved to the
    /// system default first: re-applying the same UID delivers nothing.
    private func applyMicTargetToUnifiedCapture(generation: Int, reason: MicSwitchReason) async {
        while isCurrentRecording(generation), let session = unifiedCaptureSession {
            let target = micCaptureTargetUID()
            let returnedUnderSameUID = session.currentMicDeviceUID == target && configuredMicDeviceReturned(session)
            guard session.currentMicDeviceUID != target || returnedUnderSameUID else { return }
            if returnedUnderSameUID {
                noteMicSwitchRequested(path: "unified", target: nil, reason: .returnedUnderSameUID)
                guard await session.retargetMic(deviceUID: nil) else {
                    settleRejectedMicSwitch(session)
                    return
                }
                if unifiedCaptureSession === session { unifiedConfiguredMicDeviceID = nil }
                continue
            }
            noteMicSwitchRequested(path: "unified", target: target, reason: reason)
            let updated = await session.retargetMic(deviceUID: target)
            guard isCurrentRecording(generation), unifiedCaptureSession === session else { return }
            guard updated else {
                // Rejected: capture stays where it was. A later hardware event or the capture-health
                // restart moves it.
                if micCaptureTargetUID() == target {
                    settleRejectedMicSwitch(session)
                    return
                }
                continue
            }
            unifiedConfiguredMicDeviceID = resolveDeviceID(for: target)
            // Buffers already queued come from the previous device.
            await session.drainSampleCallbacks()
            guard isCurrentRecording(generation), unifiedCaptureSession === session else { return }
            if micCaptureTargetUID() == target {
                publishMicTarget(target)
            }
        }
    }

    /// After a rejected update: when the stream is still on the device last reported, capture did
    /// not move, so that device is reported again. Otherwise it stays switching.
    private func settleRejectedMicSwitch(_ session: UnifiedCaptureSession) {
        guard let micTarget,
              session.currentMicDeviceUID == micTarget.deviceUID,
              !configuredMicDeviceReturned(session)
        else { return }
        isMicSwitchUnsettled = false
    }

    private func noteMicSwitchRequested(path: String, target: String?, reason: MicSwitchReason) {
        CaptureTrace.log("switchRequested", "target=\(target ?? "<default>") reason=\(reason.rawValue)")
        CaptureTrace.armFirstBuffer(target: target ?? "<default>")
        isMicSwitchUnsettled = true
        if reason != .restart {
            noteMicTransition()
        }
        logger.notice(
            "Mic switch requested: path=\(path, privacy: .public) target=\(target ?? "<default>", privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
    }

    private func noteMicTransition() {
        micTransitionCount += 1
        lastMicTransition = CaptureHealthMonitor.MicTransition(number: micTransitionCount, at: now())
    }

    /// Records what capture is aimed at now, and logs the first buffer that arrives for it.
    private func publishMicTarget(_ deviceUID: String?) {
        micTargetNumber += 1
        let number = micTargetNumber
        micTarget = MicCaptureTarget(deviceUID: deviceUID)
        isMicSwitchUnsettled = false
        captureGates.mic.observeNextArrival { [weak self] hostTime in
            Task { [weak self] in await self?.micTargetDeliveredFirstBuffer(number, at: hostTime) }
        }
    }

    private func micTargetDeliveredFirstBuffer(_ number: Int, at hostTime: HostNanoseconds) {
        guard number == micTargetNumber, var target = micTarget, target.firstBufferHostTime == nil else { return }
        target.firstBufferHostTime = hostTime
        micTarget = target
        capturedMicDevice = resolveCapturedMicDevice(for: target.deviceUID)
        logger.notice(
            "First mic buffer from the new device: device=\(target.deviceUID ?? "<default>", privacy: .public) hostTime=\(hostTime, privacy: .public)"
        )
    }

    /// The microphone capture is aimed at, and when its first buffer arrived. Nil when no
    /// recording runs.
    func micCaptureTarget() -> MicCaptureTarget? {
        micTarget
    }

    /// The microphone being captured. Nil when no recording runs.
    func capturedMicrophone() -> CapturedMicrophone? {
        guard isRecordingValue else { return nil }
        if captureGates.clock.isPaused, let micDeviceCapturedAtPause {
            return .capturing(micDeviceCapturedAtPause)
        }
        guard !isMicSwitchUnsettled, micTarget?.firstBufferHostTime != nil, let capturedMicDevice else {
            return .switching
        }
        return .capturing(capturedMicDevice)
    }

    /// The device behind a capture target now: the UID's device, or the system default input for
    /// a nil UID.
    private func resolveCapturedMicDevice(for deviceUID: String?) -> CapturedMicDevice? {
        let deviceID = deviceUID == nil ? hardware.defaultInputDeviceID() : resolveDeviceID(for: deviceUID)
        guard let deviceID,
              let uid = hardware.deviceUID(deviceID: deviceID),
              let name = hardware.deviceName(deviceID: deviceID)
        else { return nil }
        return CapturedMicDevice(uid: uid, name: name, isSystemDefault: deviceUID == nil)
    }

    /// Logs a removal of the captured microphone and a return of the preferred one, and says which
    /// of the two this hardware change is.
    private func noteMicDeviceChanges() -> MicSwitchReason {
        var reason = MicSwitchReason.hardwareChange
        let path: String
        let capturedUID: String?
        let capturedDeviceGone: Bool
        path = "unified"
        capturedUID = unifiedCaptureSession?.currentMicDeviceUID
        capturedDeviceGone = capturedUID != nil && resolveDeviceID(for: capturedUID) == nil
        if capturedDeviceGone, let capturedUID {
            reason = .removal
            if loggedRemovedMicUID != capturedUID {
                CaptureTrace.log("micRemovalDetected", "device=\(capturedUID)")
                loggedRemovedMicUID = capturedUID
                noteMicTransition()
                logger.notice(
                    "Captured mic removed: path=\(path, privacy: .public) device=\(capturedUID, privacy: .public)"
                )
            }
        }
        if let desired = desiredMicDeviceUID {
            if resolveDeviceID(for: desired) == nil {
                isPreferredMicAbsent = true
            } else if isPreferredMicAbsent {
                CaptureTrace.log("preferredMicReturnDetected", "device=\(desired)")
                isPreferredMicAbsent = false
                if loggedRemovedMicUID == desired { loggedRemovedMicUID = nil }
                reason = .preferredReturned
                logger.notice("Preferred mic back: path=\(path, privacy: .public) device=\(desired, privacy: .public)")
            }
        }
        return reason
    }

    private func makeSessionTitle(createdAt: Date) -> String {
        "Recording \(TimeFormatter.displayMonthDayTime(createdAt))"
    }

    private func cleanupRecordingState(deleteScreenTmpVideo: Bool = true) async {
        let screenTmpURL = makeCurrentScreenTmpVideoURL()
        deregisterMicHardwareListeners()
        if let unifiedCaptureSession {
            await unifiedCaptureSession.stop()
        }
        unifiedCaptureSession = nil
        if let screenCaptureSession {
            await screenCaptureSession.stop()
        }
        self.screenCaptureSession = nil
        liveAudioContinuation?.finish()
        liveAudioContinuation = nil
        if deleteScreenTmpVideo, let screenTmpURL, fileManager.fileExists(atPath: screenTmpURL.path) {
            try? fileManager.removeItem(at: screenTmpURL)
        }
        appAudioURL = nil
        activeAppSource = nil
        recordingStartedAt = nil
        recordingStopRequestedAt = nil
        recordingCreatedAt = nil
        recordingIdentifier = nil
        recordingFolderURL = nil
        currentSessionID = nil
        activeCapturedAppName = nil
        pendingTitle = nil
        micStartHostTime = nil
        appStartHostTime = nil
        videoStartHostTime = nil
        shouldSkipScreenMux = false
        activeCaptureDisplayID = nil
        desiredMicDeviceUID = nil
        fallbackMicDeviceUID = nil
        unifiedConfiguredMicDeviceID = nil
        unifiedStreamNumber = nil
        loggedRemovedMicUID = nil
        isPreferredMicAbsent = false
        lastMicTransition = nil
        micTarget = nil
        micTargetNumber += 1
        capturedMicDevice = nil
        isMicSwitchUnsettled = false
        micDeviceCapturedAtPause = nil
        micTransitionTail = nil
        micTransitionsInFlight = []
        queuedMicRetarget = nil
        micFileURL = nil
        restartInPlaceTask = nil
        resumeTask = nil
        micCaptureStartedAt = nil
    }

    private func releaseRecordingScopeIfNeeded() {
        guard hasScopedRecordingAccess, let recordingWorkspaceRootURL else {
            return
        }

        scopedAccessStopper(recordingWorkspaceRootURL)
        hasScopedRecordingAccess = false
        self.recordingWorkspaceRootURL = nil
    }

    private func handleScreenCaptureError() async {
        shouldSkipScreenMux = true
        let activeScreenCaptureSession = screenCaptureSession
        screenCaptureSession = nil
        captureVideoStartHostTimeIfNeeded(activeScreenCaptureSession?.videoStartHostTime)
        if let activeScreenCaptureSession {
            await activeScreenCaptureSession.stop()
        }
    }

    private func makeCurrentScreenTmpVideoURL() -> URL? {
        recordingFolderURL.map(RecordingFileLayout.screenTmpVideoURL(in:))
    }

    private func handleHardwareChange() async {
        guard isRecordingValue else { return }
        await requestMicRetarget(reason: noteMicDeviceChanges())
    }

    private func micCaptureTargetUID() -> String? {
        if resolveDeviceID(for: desiredMicDeviceUID) != nil { return desiredMicDeviceUID }
        if resolveDeviceID(for: fallbackMicDeviceUID) != nil { return fallbackMicDeviceUID }
        return nil
    }

    private func resolveDeviceID(for deviceUID: String?) -> AudioDeviceID? {
        guard let deviceUID, !deviceUID.isEmpty else {
            return nil
        }
        guard let allDevices = try? hardware.allDeviceIDs() else {
            return nil
        }
        return allDevices.first(where: {
            hardware.deviceUID(deviceID: $0) == deviceUID && hardware.isUsableMicrophone(deviceID: $0)
        })
    }

    private func registerMicHardwareListeners() {
        guard !hasRegisteredHardwareListeners,
              let hardwarePropertyListener
        else {
            return
        }
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafePointer(to: &devicesAddress) { addressPointer in
            AudioObjectAddPropertyListenerBlock(
                recordingAudioObjectSystemObjectID,
                addressPointer,
                hardwareListenerQueue,
                hardwarePropertyListener
            )
        }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafePointer(to: &defaultInputAddress) { addressPointer in
            AudioObjectAddPropertyListenerBlock(
                recordingAudioObjectSystemObjectID,
                addressPointer,
                hardwareListenerQueue,
                hardwarePropertyListener
            )
        }
        hasRegisteredHardwareListeners = true
    }

    private func deregisterMicHardwareListeners() {
        guard hasRegisteredHardwareListeners,
              let hardwarePropertyListener
        else {
            return
        }

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafePointer(to: &devicesAddress) { addressPointer in
            AudioObjectRemovePropertyListenerBlock(
                recordingAudioObjectSystemObjectID,
                addressPointer,
                hardwareListenerQueue,
                hardwarePropertyListener
            )
        }

        var defaultInputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = withUnsafePointer(to: &defaultInputAddress) { addressPointer in
            AudioObjectRemovePropertyListenerBlock(
                recordingAudioObjectSystemObjectID,
                addressPointer,
                hardwareListenerQueue,
                hardwarePropertyListener
            )
        }
        hasRegisteredHardwareListeners = false
    }

    /// The earlier of the two audio start times, which the timeline mixdown is anchored to.
    static func audioAnchorHostTime(mic: HostNanoseconds, app: HostNanoseconds?) -> HostNanoseconds {
        app.map { min(mic, $0) } ?? mic
    }

    func captureMicStartHostTimeIfNeeded(_ hostTime: HostNanoseconds) {
        guard micStartHostTime == nil else {
            return
        }
        micStartHostTime = hostTime
    }

    func captureAppStartHostTimeIfNeeded(_ hostTime: HostNanoseconds) {
        guard appStartHostTime == nil else {
            return
        }
        appStartHostTime = hostTime
    }

    func captureVideoStartHostTimeIfNeeded(_ hostTime: HostNanoseconds?) {
        guard videoStartHostTime == nil, let hostTime else {
            return
        }
        videoStartHostTime = hostTime
    }

    func capturedHostTimes() -> (mic: HostNanoseconds?, app: HostNanoseconds?, video: HostNanoseconds?) {
        (micStartHostTime, appStartHostTime, videoStartHostTime)
    }

    func runMixdown(
        sessionID: UUID,
        micURL: URL,
        appURL: URL?,
        mixdownURL: URL,
        micStartHostTime: HostNanoseconds,
        appStartHostTime: HostNanoseconds?
    ) async {
        _ = await mixdownCoordinator.runMixdown(
            sessionID: sessionID,
            micURL: micURL,
            appURL: appURL,
            mixdownURL: mixdownURL,
            micStartHostTime: micStartHostTime,
            appStartHostTime: appStartHostTime,
            timelineMixdown: recordingAudioSyncFlags.isTimelineMixdownEnabled
        )
    }

}
