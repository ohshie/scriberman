import AVFoundation
import AudioToolbox
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

/// What an engine microphone tap sends to live transcription.
enum MicCaptureOutput: Sendable {
    /// Kept samples, their rate, and the adjusted and raw host time of the first one.
    case audio(samples: [Float], sampleRate: Double, hostTime: HostNanoseconds, rawHostTime: HostNanoseconds)
    /// All audio from before pause number `n` has been sent.
    case pauseMarker(Int)
}

typealias MicBufferHandler = @Sendable (MicCaptureOutput) -> Void

protocol MicCaptureControlling: AnyObject {
    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        micFileURL: URL,
        micStreamer: AudioFileStreamer,
        gate: CaptureAudioGate,
        voiceProcessingEnabled: Bool,
        applyVoiceProcessing: @Sendable (AVAudioInputNode, Bool) -> Void,
        onFirstHostTime: @escaping @Sendable (HostNanoseconds) -> Void,
        onBuffer: @escaping MicBufferHandler
    ) throws
    func stopCapture()
    func retargetDevice(_ deviceID: AudioDeviceID?) throws
    func isCaptureRunning() -> Bool
}

final class AVAudioEngineMicCaptureController: MicCaptureControlling {
    private var audioEngine: AVAudioEngine?
    /// Counts starts, so log lines tell one capture's buffers from the next one's.
    private var captureGeneration = 0

    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        micFileURL _: URL,
        micStreamer: AudioFileStreamer,
        gate: CaptureAudioGate,
        voiceProcessingEnabled: Bool,
        applyVoiceProcessing: @Sendable (AVAudioInputNode, Bool) -> Void,
        onFirstHostTime: @escaping @Sendable (HostNanoseconds) -> Void,
        onBuffer: @escaping MicBufferHandler
    ) throws {
        stopCapture()
        captureGeneration += 1

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let deviceID, deviceID != 0 {
            try setInputDevice(deviceID, on: inputNode)
        }

        applyVoiceProcessing(inputNode, voiceProcessingEnabled)

        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecordingError.failedToStart("Invalid audio input format.")
        }

        let tap = try EngineMicTap(
            inputFormat: inputFormat,
            targetFormat: targetFormat,
            micStreamer: micStreamer,
            gate: gate,
            captureGeneration: captureGeneration,
            onFirstHostTime: onFirstHostTime,
            onBuffer: onBuffer
        )

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, audioTime in
            guard self != nil else {
                return
            }
            tap.process(
                buffer,
                hostTime: Self.hostTime(of: audioTime),
                sampleTime: audioTime.isSampleTimeValid ? Double(audioTime.sampleTime) : nil
            )
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    /// Host time of a tap buffer, or nil when the tap reports none.
    static func hostTime(of audioTime: AVAudioTime) -> HostNanoseconds? {
        audioTime.hostTime != 0 ? HostNanoseconds(machTicks: audioTime.hostTime) : nil
    }

    func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
    }

    func retargetDevice(_ deviceID: AudioDeviceID?) throws {
        guard let audioEngine else {
            return
        }
        try setInputDevice(deviceID, on: audioEngine.inputNode)
    }

    func isCaptureRunning() -> Bool {
        audioEngine?.isRunning ?? false
    }

    private func setInputDevice(_ deviceID: AudioDeviceID?, on inputNode: AVAudioInputNode) throws {
        guard let deviceID, deviceID != 0 else {
            return
        }
        guard let inputAudioUnit = inputNode.audioUnit else {
            throw RecordingError.failedToStart("Audio input unit is unavailable.")
        }
        var targetDeviceID = deviceID
        let status = withUnsafePointer(to: &targetDeviceID) { pointer in
            AudioUnitSetProperty(
                inputAudioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                pointer,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        if status != noErr {
            throw RecordingError.failedToStart("Unable to route microphone input.")
        }
    }
}

/// What an engine microphone tap does with its buffers: convert, cut paused audio, write and
/// deliver. Separate from the engine so it can be fed without hardware.
///
/// The converter follows each buffer's own format. A route change can hand the tap buffers at the
/// new device's rate; a converter built for the old rate rejects them (finding 11).
///
/// @unchecked Sendable: used only from the tap's callback thread.
final class EngineMicTap: @unchecked Sendable {
    private static let logger = Logger(subsystem: "Scriberman", category: "RecordingService")
    /// Buffers logged at the start of a capture and after a format change or a timing mismatch.
    private static let loggedBuffersPerEvent = 10

    private let targetFormat: AVAudioFormat
    private let micStreamer: AudioFileStreamer
    private let gate: CaptureAudioGate
    private let onFirstHostTime: @Sendable (HostNanoseconds) -> Void
    private let onBuffer: MicBufferHandler
    private let captureGeneration: Int
    private var conversion: GatedAudioConversion
    private var converterSourceFormat: AVAudioFormat
    private var diagnostics = BufferDiagnostics()

    init(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        micStreamer: AudioFileStreamer,
        gate: CaptureAudioGate,
        captureGeneration: Int = 0,
        onFirstHostTime: @escaping @Sendable (HostNanoseconds) -> Void,
        onBuffer: @escaping MicBufferHandler
    ) throws {
        guard let conversion = Self.makeConversion(from: inputFormat, to: targetFormat, gate: gate) else {
            throw RecordingError.failedToStart("Unable to create mic audio converter.")
        }
        self.conversion = conversion
        self.converterSourceFormat = inputFormat
        self.targetFormat = targetFormat
        self.micStreamer = micStreamer
        self.gate = gate
        self.captureGeneration = captureGeneration
        self.onFirstHostTime = onFirstHostTime
        self.onBuffer = onBuffer
    }

    /// A conversion from `source` to `target`, with no converter when they match. Nil when no
    /// converter can be made.
    private static func makeConversion(
        from source: AVAudioFormat,
        to target: AVAudioFormat,
        gate: CaptureAudioGate
    ) -> GatedAudioConversion? {
        let matchesTarget = source.sampleRate == target.sampleRate
            && source.channelCount == target.channelCount
            && source.commonFormat == target.commonFormat
            && source.isInterleaved == target.isInterleaved
        if matchesTarget {
            return GatedAudioConversion(converter: nil, targetFormat: target, gate: gate)
        }
        return AVAudioConverter(from: source, to: target).map {
            GatedAudioConversion(converter: $0, targetFormat: target, gate: gate)
        }
    }

    /// - Parameter sampleTime: the tap's sample time for the buffer, for diagnostics only.
    func process(_ buffer: AVAudioPCMBuffer, hostTime: HostNanoseconds?, sampleTime: Double? = nil) {
        gate.recordArrival()
        if let hostTime, let firstKept = gate.firstKeptHostTime(
            startingAt: hostTime,
            frameCount: Int(buffer.frameLength),
            sampleRate: buffer.format.sampleRate
        ) {
            onFirstHostTime(firstKept)
        }

        let formatChanged = buffer.format != converterSourceFormat
        if formatChanged {
            Self.logger.notice(
                "Engine mic tap format changed (generation \(self.captureGeneration, privacy: .public)): \(Self.describe(self.converterSourceFormat), privacy: .public) -> \(Self.describe(buffer.format), privacy: .public)"
            )
            guard let replacement = Self.makeConversion(from: buffer.format, to: targetFormat, gate: gate) else {
                Self.logger.error(
                    "Engine mic tap dropped a buffer (generation \(self.captureGeneration, privacy: .public)): no converter from \(Self.describe(buffer.format), privacy: .public)"
                )
                return
            }
            conversion = replacement
            converterSourceFormat = buffer.format
        }

        var outputFrames = 0
        conversion.process(buffer, hostTime: hostTime) { event in
            switch event {
            case .audio(let audio):
                outputFrames += Int(audio.buffer.frameLength)
                micStreamer.write(buffer: audio.buffer, hostTimeNanos: audio.hostTime?.nanoseconds)
                guard let adjusted = audio.hostTime, let raw = audio.rawHostTime else { return }
                onBuffer(.audio(
                    samples: AudioDownmixer.toMono(buffer: audio.buffer),
                    sampleRate: audio.buffer.format.sampleRate,
                    hostTime: adjusted,
                    rawHostTime: raw
                ))
            case .pauseMarker(let number):
                onBuffer(.pauseMarker(number))
            }
        }
        logDiagnostics(buffer, hostTime: hostTime, sampleTime: sampleTime, outputFrames: outputFrames, formatChanged: formatChanged)
    }

    /// Logs a buffer at the start of a capture, after a format change, and when the time between
    /// buffers disagrees with the previous buffer's length at its labelled rate.
    private func logDiagnostics(
        _ buffer: AVAudioPCMBuffer,
        hostTime: HostNanoseconds?,
        sampleTime: Double?,
        outputFrames: Int,
        formatChanged: Bool
    ) {
        let inputFrames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let previous = diagnostics.previous
        diagnostics.previous = .init(hostTime: hostTime, sampleTime: sampleTime, frames: inputFrames, sampleRate: rate)
        diagnostics.buffersSeen += 1

        var hostDeltaMs: Double?
        var expectedDeltaMs: Double?
        if let previous, let hostTime, let previousHost = previous.hostTime, previous.sampleRate > 0 {
            hostDeltaMs = (Double(hostTime.nanoseconds) - Double(previousHost.nanoseconds)) / 1e6
            expectedDeltaMs = Double(previous.frames) / previous.sampleRate * 1000
        }
        var sampleDelta: Double?
        if let sampleTime, let previousSampleTime = previous?.sampleTime {
            sampleDelta = sampleTime - previousSampleTime
        }

        // A gap between buffers is an outage, not a mismatch; only a shorter interval than the
        // labelled length is: the buffers hold audio faster than real time.
        let mismatch = hostDeltaMs.flatMap { host in
            expectedDeltaMs.map { expected in expected > 0 && host < expected * 0.75 }
        } ?? false

        if diagnostics.buffersSeen == 1 || formatChanged {
            diagnostics.remainingLogged = Self.loggedBuffersPerEvent
        } else if mismatch && !diagnostics.lastWasMismatch {
            diagnostics.remainingLogged = Self.loggedBuffersPerEvent
        }
        diagnostics.lastWasMismatch = mismatch
        guard diagnostics.remainingLogged > 0 else { return }
        diagnostics.remainingLogged -= 1

        let converter = Self.describe(converterSourceFormat)
        Self.logger.notice(
            "Engine mic buffer (generation \(self.captureGeneration, privacy: .public)): format=\(Self.describe(buffer.format), privacy: .public) converter=\(converter, privacy: .public) in=\(inputFrames, privacy: .public) out=\(outputFrames, privacy: .public) hostDeltaMs=\(Self.describe(hostDeltaMs), privacy: .public) expectedMs=\(Self.describe(expectedDeltaMs), privacy: .public) sampleDelta=\(Self.describe(sampleDelta), privacy: .public) mismatch=\(mismatch, privacy: .public)"
        )
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
    }

    private static func describe(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "none"
    }

    private struct BufferDiagnostics {
        struct Buffer {
            let hostTime: HostNanoseconds?
            let sampleTime: Double?
            let frames: Int
            let sampleRate: Double
        }
        var previous: Buffer?
        var buffersSeen = 0
        var remainingLogged = 0
        var lastWasMismatch = false
    }
}

/// The `AVAudioRecorder` microphone fallback, behind a protocol so tests can drive it.
protocol MicRecorderFallback: AnyObject {
    func record() -> Bool
    func pause()
    func stop()
    func updateMeters()
    func averagePower(forChannel channelNumber: Int) -> Float
}

extension AVAudioRecorder: MicRecorderFallback {}

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
    /// The device is not known: the recorder fallback records the system input.
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
    /// Makes the recorder fallback for a file with the given settings.
    typealias RecorderFallbackFactory = @Sendable (URL, [String: Any]) throws -> any MicRecorderFallback
    /// Reads whether voice processing is on.
    typealias VoiceProcessingSetting = @Sendable () async -> Bool

    /// A capture session about to start its ScreenCaptureKit stream.
    enum CaptureSessionStart: Sendable {
        case unified(UnifiedCaptureSession)
        case appAudio(AppAudioCaptureSession)
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
    private let appAudioSettings: AppAudioSettings
    private let hardware: AudioDeviceHardwareProviding
    private let micCaptureController: MicCaptureControlling
    private let permissionChecker: PermissionChecker
    private let scopedAccessStarter: ScopedAccessStarter
    private let scopedAccessStopper: ScopedAccessStopper
    private let makeScreenCaptureSession: ScreenCaptureSessionFactory
    // Injected for testing; nil uses the real setVoiceProcessingEnabled(_:)
    private let voiceProcessingPropertySetter: (@Sendable (AVAudioInputNode) throws -> Void)?
    private let applyDefaultTag: DefaultTagApplier
    private let now: DateProvider
    /// The host clock that pauses and the stop are timed by.
    private let hostNow: HostTimeProvider
    private let startCaptureSession: CaptureSessionStarter
    private let makeRecorderFallback: RecorderFallbackFactory
    private let voiceProcessingSetting: VoiceProcessingSetting

    private var audioEngine: AVAudioEngine?
    private let micStreamer = AudioFileStreamer(label: "mic")
    private var audioRecorder: (any MicRecorderFallback)?
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
    /// The preferred device that refused explicit routing at start. It is not targeted again until
    /// it has left the device list and returned.
    private var routeRefusedMicDeviceID: AudioDeviceID?
    private var currentCaptureDeviceID: AudioDeviceID?
    private var micFileURL: URL?
    private let micTargetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private var isRecoveringMicCapture = false
    private var hasScopedRecordingAccess = false
    private var recordingWorkspaceRootURL: URL?
    private var activeCapturedAppName: String?
    private var pendingTitle: String?
    private var appAudioCaptureSession: AppAudioCaptureSession?
    private var unifiedCaptureSession: UnifiedCaptureSession?
    /// Retained so the start safety net can repeat a capture start with identical inputs.
    private var activeAppFileURL: URL?
    private var activeAppProcessID: pid_t?
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
    private var micRecoveryRetryTask: Task<Void, Never>?
    /// Advanced at each recording start. An operation that suspended compares it with the value it
    /// started with, so a late completion never acts on a later recording.
    private var recordingGeneration = 0
    /// When the microphone capture now running was started, by the host clock.
    private var micCaptureStartedAt: HostNanoseconds?
    /// The engine recovery in flight. A caller that needs its result waits for it.
    private var micRecoveryTask: Task<Bool, Never>?
    /// The in-place capture restart in flight. A second request waits for it.
    private var restartInPlaceTask: Task<Bool, Never>?
    /// The resume in flight. Pause and resume requests made during it wait for it.
    private var resumeTask: Task<Bool, Never>?
    /// The last microphone transition queued: a capture target update, a unified capture restart
    /// or an engine recovery. Each one waits for the one queued before it.
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
    private var appStreamNumber: Int?
    /// The UID engine capture was started on; nil for the system default.
    private var currentCaptureDeviceUID: String?
    /// The removed microphone already logged, so a removal is logged once.
    private var loggedRemovedMicUID: String?
    /// True while the preferred microphone is absent, so its return is logged.
    private var isPreferredMicAbsent = false
    /// The microphone capture is aimed at, numbered so a late first-buffer notice for an earlier
    /// target is ignored.
    private var micTarget: MicCaptureTarget?
    private var micTargetNumber = 0
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
    // nonisolated(unsafe): written once in init on the actor; read only in deinit; lifetime matches the actor
    nonisolated(unsafe) private var engineConfigurationObserver: NSObjectProtocol?
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

    private var isRecorderFallbackActive: Bool {
#if DEBUG
        audioRecorder != nil || recorderFallbackActiveForTesting
#else
        audioRecorder != nil
#endif
    }

    /// Thrown when the recording ended or changed while a capture start was suspended.
    private struct CaptureStartAbandoned: Error {}
    private var audioLevelValue: Float = 0
#if DEBUG
    private var recorderFallbackActiveForTesting = false
    private var stopRecordingCallCount = 0
#endif

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        appAudioSettings: AppAudioSettings,
        hardware: AudioDeviceHardwareProviding = CoreAudioDeviceHardware(),
        micCaptureController: MicCaptureControlling? = nil,
        notificationCenter: NotificationCenter = .default,
        mixdownCoordinator: (any RecordingMixdownCoordinating)? = nil,
        screenVideoMuxer: (any ScreenVideoMuxing)? = nil,
        finalizer: RecordingFinalizer? = nil,
        permissionChecker: @escaping PermissionChecker = RecordingPermissionService.ensureMicrophonePermission,
        scopedAccessStarter: @escaping ScopedAccessStarter = { $0.startAccessingSecurityScopedResource() },
        scopedAccessStopper: @escaping ScopedAccessStopper = { $0.stopAccessingSecurityScopedResource() },
        screenCaptureSessionFactory: @escaping ScreenCaptureSessionFactory = { ScreenCaptureSession() },
        voiceProcessingPropertySetter: (@Sendable (AVAudioInputNode) throws -> Void)? = nil,
        defaultTagApplier: @escaping DefaultTagApplier = { try TagService().applyDefaultTag(to: $0, in: $1) },
        now: @escaping DateProvider = { Date() },
        hostNow: @escaping HostTimeProvider = { HostNanoseconds(machTicks: mach_absolute_time()) },
        captureSessionStarter: @escaping CaptureSessionStarter = { start in
            switch start {
            case .unified(let session):
                try await session.start()
            case .appAudio(let session):
                try await session.start()
            }
        },
        recorderFallbackFactory: @escaping RecorderFallbackFactory = { url, settings in
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            return recorder
        },
        voiceProcessingSetting: VoiceProcessingSetting? = nil
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.appAudioSettings = appAudioSettings
        self.hardware = hardware
        self.micCaptureController = micCaptureController ?? AVAudioEngineMicCaptureController()
        self.notificationCenter = notificationCenter
        self.permissionChecker = permissionChecker
        self.scopedAccessStarter = scopedAccessStarter
        self.scopedAccessStopper = scopedAccessStopper
        self.makeScreenCaptureSession = screenCaptureSessionFactory
        self.voiceProcessingPropertySetter = voiceProcessingPropertySetter
        self.applyDefaultTag = defaultTagApplier
        self.now = now
        self.hostNow = hostNow
        self.startCaptureSession = captureSessionStarter
        self.makeRecorderFallback = recorderFallbackFactory
        self.voiceProcessingSetting = voiceProcessingSetting ?? { await MainActor.run { appAudioSettings.voiceProcessingEnabled } }
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

        engineConfigurationObserver = notificationCenter.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task {
                await self?.handleAudioEngineConfigurationChange()
            }
        }
    }

    deinit {
        if let engineConfigurationObserver {
            notificationCenter.removeObserver(engineConfigurationObserver)
        }
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
        self.activeAppFileURL = activeAppFileURL
        self.activeAppProcessID = activeAppProcessID
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

    func setMicRecoveryStateForTesting(
        desiredMicDeviceUID: String?,
        micFileURL: URL?,
        isRecoveringMicCapture: Bool = false,
        recorderFallbackActive: Bool = false,
        currentCaptureDeviceID: AudioDeviceID? = nil,
        hasRecoveryRetryTask: Bool = false,
        fallbackMicDeviceUID: String? = nil
    ) {
        self.desiredMicDeviceUID = desiredMicDeviceUID
        self.fallbackMicDeviceUID = fallbackMicDeviceUID
        self.micFileURL = micFileURL
        self.isRecoveringMicCapture = isRecoveringMicCapture
        self.recorderFallbackActiveForTesting = recorderFallbackActive
        self.currentCaptureDeviceID = currentCaptureDeviceID
        if hasRecoveryRetryTask {
            self.micRecoveryRetryTask = Task {}
        } else {
            self.micRecoveryRetryTask?.cancel()
            self.micRecoveryRetryTask = nil
        }
    }

    func simulateAudioEngineConfigurationChangeForTesting() async {
        await handleAudioEngineConfigurationChange()
    }

    /// Test seam: the count is only advanced by a real mid-session restart, which needs a live
    /// `SCStream`.
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

    func recoveryDebugStateForTesting() -> (
        desiredMicDeviceUID: String?,
        currentCaptureDeviceID: AudioDeviceID?,
        isRecoveringMicCapture: Bool,
        hasRecoveryRetryTask: Bool
    ) {
        (
            desiredMicDeviceUID,
            currentCaptureDeviceID,
            isRecoveringMicCapture,
            micRecoveryRetryTask != nil
        )
    }

    func performMicRecoveryRetryAttemptForTesting() async {
        _ = await retryMicCaptureFromRetryLoop()
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
        if let unifiedCaptureSession {
            return (unifiedCaptureSession.micLastActivityAt, unifiedCaptureSession.appLastActivityAt)
        }
        // Legacy path. Note the AVAudioRecorder fallback does not route through
        // AudioFileStreamer, so mic activity is unavailable there and reports nil.
        let mic = audioRecorder == nil ? micStreamer.lastActivityAt : nil
        return (mic, appAudioCaptureSession?.lastActivityAt)
    }

    /// Frames written per source since capture started, plus write failures.
    ///
    /// This is the signal the start safety net verifies against, deliberately in preference to
    /// `audioLevels()` or `activityTimestamps()`: frames are produced at the capture sample rate
    /// whether or not anyone is speaking, so a silent room reads as healthy. Levels and activity
    /// both require sound above a floor and would fail a recording that simply started quiet.
    ///
    /// `mic` is `nil` — not zero — under the `AVAudioRecorder` fallback, which does not write
    /// through `AudioFileStreamer`. Callers must not read that as a dead capture. `app` is `nil`
    /// when app audio is not being captured at all.
    func captureFrameCounts() async -> (mic: Int64?, app: Int64?, micWriteFailures: Int, appWriteFailures: Int) {
        if let unifiedCaptureSession {
            return (
                unifiedCaptureSession.micFramesWritten,
                appAudioURL == nil ? nil : unifiedCaptureSession.appFramesWritten,
                unifiedCaptureSession.micWriteFailureCount,
                unifiedCaptureSession.appWriteFailureCount
            )
        }
        let mic = isRecorderFallbackActive ? nil : micStreamer.framesWritten
        return (
            mic,
            appAudioCaptureSession?.framesWritten,
            isRecorderFallbackActive ? 0 : micStreamer.writeFailureCount,
            appAudioCaptureSession?.writeFailureCount ?? 0
        )
    }

    func audioLevels() async -> (mic: Float, app: Float) {
        guard !isPaused() else {
            audioLevelValue = 0
            return (0, 0)
        }

        if let unifiedCaptureSession {
            let mic = unifiedCaptureSession.micAudioLevel
            let app = unifiedCaptureSession.appAudioLevel
            audioLevelValue = max(mic, app)
            return (mic, app)
        }

        var micLevel: Float = 0

        if let audioRecorder {
            audioRecorder.updateMeters()
            let averagePower = audioRecorder.averagePower(forChannel: 0)
            if averagePower.isFinite {
                let normalized = powf(10, averagePower / 20)
                micLevel = max(micLevel, min(max(normalized, 0), 1))
            }
        }

        micLevel = max(micLevel, micStreamer.audioLevel)
        let appLevel = appAudioCaptureSession?.audioLevel ?? 0

        audioLevelValue = max(micLevel, appLevel)
        return (micLevel, appLevel)
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
        guard isRecordingValue, streamNumber == unifiedStreamNumber || streamNumber == appStreamNumber else {
            logger.notice(
                "Ignored a stale capture stream callback: stream=\(streamNumber, privacy: .public) currentUnified=\(self.unifiedStreamNumber.map(String.init) ?? "none", privacy: .public) currentApp=\(self.appStreamNumber.map(String.init) ?? "none", privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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

    private func reportStreamFailures(of session: AppAudioCaptureSession) -> Int {
        nextCaptureStreamNumber += 1
        let streamNumber = nextCaptureStreamNumber
        session.onStreamStopped = { [weak self] error in
            Task { [weak self] in await self?.reportCaptureStreamFailure(error, fromStream: streamNumber) }
        }
        return streamNumber
    }

    /// Everything the capture-health monitor needs, gathered in one actor hop.
    ///
    /// `streamFailureCount` is deliberately not consuming, unlike `consumePendingError()`: the
    /// monitor observes it every tick, while the pending error is spent once when a failure is
    /// reported to the user and written to the session log.
    func captureHealthSnapshot() async -> CaptureHealthMonitor.Snapshot {
        let counts = await captureFrameCounts()
        return CaptureHealthMonitor.Snapshot(
            micFrames: counts.mic,
            appFrames: counts.app,
            streamFailureCount: captureStreamFailureCount,
            handledStreamFailureCount: handledStreamFailureCount
        )
    }

    /// Starts audio capture for a recording: unified ScreenCaptureKit when enabled and an app was
    /// selected, otherwise the legacy engine path with its device and recorder fallbacks.
    ///
    /// Extracted so the start safety net can restart capture without disturbing the session,
    /// folder, or screen capture around it. Callers own session state; this owns only capture.
    private func startAudioCapture(
        micFileURL: URL,
        appFileURL: URL,
        appProcessID: pid_t?
    ) async throws {
        var unifiedStarted = false
        if recordingAudioSyncFlags.isUnifiedCaptureEnabled, let appProcessID {
            do {
                let unified = UnifiedCaptureSession(
                    micFileURL: micFileURL,
                    appFileURL: appFileURL,
                    processID: appProcessID,
                    micDeviceUID: micCaptureTargetUID(),
                    liveAudioContinuation: liveAudioContinuation,
                    onMicFirstHostTime: { [weak self, clock = liveAudioClock] hostTime in
                        clock?.observe(hostTime)
                        Task { [weak self] in await self?.captureMicStartHostTimeIfNeeded(hostTime) }
                    },
                    onAppFirstHostTime: { [weak self, clock = liveAudioClock] hostTime in
                        clock?.observe(hostTime)
                        Task { [weak self] in await self?.captureAppStartHostTimeIfNeeded(hostTime) }
                    },
                    gates: captureGates
                )
                let streamNumber = reportStreamFailures(of: unified)
                unifiedStreamNumber = streamNumber
                do {
                    try await startCaptureSession(.unified(unified))
                } catch {
                    if unifiedStreamNumber == streamNumber { unifiedStreamNumber = nil }
                    throw error
                }
                self.unifiedCaptureSession = unified
                self.unifiedConfiguredMicDeviceID = resolveDeviceID(for: unified.currentMicDeviceUID)
                self.appAudioURL = appFileURL
                self.micCaptureStartedAt = hostNow()
                publishMicTarget(unified.currentMicDeviceUID)
                unifiedStarted = true
            } catch {
                logger.warning("Unified capture failed to start; falling back to legacy capture. error=\(error.localizedDescription, privacy: .public)")
            }
        }

        if !unifiedStarted {
        try micStreamer.prepare(url: micFileURL, format: micTargetFormat)

        if let appProcessID {
            let appSession = AppAudioCaptureSession(
                fileURL: appFileURL,
                processID: appProcessID,
                onFirstBufferHostTime: { [weak self, clock = liveAudioClock] hostTime in
                    clock?.observe(hostTime)
                    Task { [weak self] in
                        await self?.captureAppStartHostTimeIfNeeded(hostTime)
                    }
                },
                liveAudioContinuation: liveAudioContinuation,
                gate: captureGates.app
            )
            let streamNumber = reportStreamFailures(of: appSession)
            appStreamNumber = streamNumber
            do {
                try await startCaptureSession(.appAudio(appSession))
            } catch {
                if appStreamNumber == streamNumber { appStreamNumber = nil }
                throw error
            }
            self.appAudioCaptureSession = appSession
            self.appAudioURL = appFileURL
        } else {
            self.appAudioCaptureSession = nil
            self.appAudioURL = nil
        }

        do {
            try await startMicCapture(micFileURL: micFileURL, liveContinuation: liveAudioContinuation)
        } catch is CaptureStartAbandoned {
            throw CaptureStartAbandoned()
        } catch {
            // Bluetooth/external devices can fail explicit routing on some setups.
            // Retry with the default input device so the live stream path stays active.
            if desiredMicDeviceUID != nil {
                logger.warning(
                    "Mic capture failed for selected device; retrying on default input. error=\(error.localizedDescription, privacy: .public)"
                )
                routeRefusedMicDeviceID = resolveDeviceID(for: desiredMicDeviceUID)
                fallbackMicDeviceUID = nil
                do {
                    try await startMicCapture(micFileURL: micFileURL, liveContinuation: liveAudioContinuation)
                } catch is CaptureStartAbandoned {
                    throw CaptureStartAbandoned()
                } catch {
                    logger.warning(
                        "Default-device mic capture retry failed; falling back to recorder. error=\(error.localizedDescription, privacy: .public)"
                    )
                    try startRecorderFallback(to: micFileURL)
                }
            } else {
                try startRecorderFallback(to: micFileURL)
            }
        }
        } // end if !unifiedStarted
    }

    /// Tears audio capture down and starts it again with the same configuration and the same
    /// files, leaving the session, its folder, and screen capture untouched.
    ///
    /// Used by the start safety net when verification finds that nothing is being written.
    /// Overwriting the existing audio files is safe for exactly one reason: this runs only when
    /// zero frames were written, so there is nothing to lose. Any future caller that restarts
    /// after a partial failure must revisit that.
    func restartAudioCapture() async -> Bool {
        guard isRecordingValue, let micFileURL, let activeAppFileURL else {
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
                appFileURL: activeAppFileURL,
                appProcessID: activeAppProcessID
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
        guard isCurrentRecording(generation), let activeAppFileURL, let micFileURL else {
            return false
        }

        // Mic-only recordings never take the unified path, and the engine path already has its own
        // recovery in `mic-capture-resilience` — which likewise does not re-prepare the writer.
        guard let existing = unifiedCaptureSession else {
            logger.notice("Mid-session restart delegating to engine-path mic recovery.")
            return await recoverMicCapture(reason: .restart)
        }

        let startedAt = Date()
        let framesBefore = (mic: existing.micFramesWritten, app: existing.appFramesWritten)
        await existing.stopStreamPreservingOutput()
        guard isCurrentRecording(generation), unifiedCaptureSession === existing else {
            return false
        }
        Self.sendStartedPauseMarkers(gates: captureGates, to: liveAudioContinuation, mic: true, app: true)
        let reused = existing.streamers
        let targetUID = micCaptureTargetUID()
        noteMicSwitchRequested(path: "unified", target: targetUID, reason: .restart)

        let replacement = UnifiedCaptureSession(
            micFileURL: micFileURL,
            appFileURL: activeAppFileURL,
            processID: activeAppProcessID ?? 0,
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
        micRecoveryRetryTask?.cancel()
        micRecoveryRetryTask = nil
        if let unifiedCaptureSession {
            await unifiedCaptureSession.stop()
        }
        unifiedCaptureSession = nil
        if let appAudioCaptureSession {
            await appAudioCaptureSession.stop()
        }
        appAudioCaptureSession = nil
        unifiedStreamNumber = nil
        appStreamNumber = nil
        stopMicCapture()
        audioRecorder?.stop()
        audioRecorder = nil
        micStreamer.close()
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
            throw error
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
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            if let micDeviceID, micDeviceID != 0 {
                fallbackMicDeviceUID = hardware.deviceUID(deviceID: micDeviceID)
            } else {
                fallbackMicDeviceUID = nil
            }
            desiredMicDeviceUID = preferredMicDeviceUID ?? fallbackMicDeviceUID
            routeRefusedMicDeviceID = nil
            isPreferredMicAbsent = desiredMicDeviceUID != nil && resolveDeviceID(for: desiredMicDeviceUID) == nil
            // Phase 2: for mic+app recordings, capture both from one ScreenCaptureKit stream
            // (shared clock) when enabled. Falls back to the legacy AVAudioEngine + separate
            // SCStream path on any failure.
            self.activeAppFileURL = appFileURL
            self.activeAppProcessID = appProcessID
            self.recordingAudioSyncFlags = audioSyncFlags
            try await startAudioCapture(
                micFileURL: micFileURL,
                appFileURL: appFileURL,
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
            self.activeCapturedAppName = capturedAppName
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
                capturedAppName: capturedAppName,
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
                "Recording \(session.id, privacy: .public) audio-sync flags: timelineMixdown=\(audioSyncFlags.isTimelineMixdownEnabled, privacy: .public) unifiedCapture=\(audioSyncFlags.isUnifiedCaptureEnabled, privacy: .public) captureHealthRecovery=\(audioSyncFlags.isCaptureHealthRecoveryEnabled, privacy: .public) unifiedStarted=\(self.unifiedCaptureSession != nil, privacy: .public)"
            )
            registerMicHardwareListeners()
            didStart = true
            // A device removed or returned while capture started is not seen by the listeners,
            // which start only now.
            await requestMicRetarget(reason: .start)
            return session.id
        } catch {
            stopMicCapture()
            audioRecorder?.stop()
            await appAudioCaptureSession?.stop()
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
        let appFramesAtStop: Int64? = if let unifiedCaptureSession {
            appAudioURL == nil ? nil : unifiedCaptureSession.appFramesWritten
        } else {
            appAudioCaptureSession?.framesWritten
        }
        let micFramesAtStop: Int64? = if let unifiedCaptureSession {
            unifiedCaptureSession.micFramesWritten
        } else if audioRecorder != nil {
            // The AVAudioRecorder fallback does not write through AudioFileStreamer, so there is
            // no frame count to measure coverage against.
            nil
        } else {
            micStreamer.framesWritten
        }
        // Write failures are read here for the same reason: the counters live on the capture
        // sessions, which are released below.
        var writeFailuresAtStop: Int = if let unifiedCaptureSession {
            unifiedCaptureSession.micWriteFailureCount + unifiedCaptureSession.appWriteFailureCount
        } else {
            micStreamer.writeFailureCount + (appAudioCaptureSession?.writeFailureCount ?? 0)
        }
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
        stopMicCapture()
        audioRecorder?.stop()
        micStreamer.close()
        await appAudioCaptureSession?.stop()
        appAudioCaptureSession = nil
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
    /// The `AVAudioRecorder` fallback, which has no buffers to discard, is paused itself.
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
            audioRecorder?.pause()
            screenCaptureSession?.recordingDidPause()
        }
        return true
    }

    /// Ends the pause. True when the recording is running, including when it was not paused.
    ///
    /// Sources that died during the pause are restarted first, whatever the capture-health recovery
    /// flag is. If the microphone can't be restarted, resume fails and the recording stays paused;
    /// a legacy app stream that can't be restarted is left out. A request made during a resume
    /// waits for it and gets its result.
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
            await restartDeadLegacyAppStream(generation: generation)
            guard isCurrentRecording(generation) else { return false }
        } while !micTransitionsInFlight.isEmpty
        // Recorded again only now, so it captures nothing while the clock is still paused.
        if let audioRecorder, !audioRecorder.record() {
            logger.error("Resume failed: the recorder fallback did not restart. The recording stays paused.")
            return false
        }
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
        await appAudioCaptureSession?.drainSampleCallbacks()
        Self.sendStartedPauseMarkers(
            gates: gates, to: continuation, mic: true, app: includesApp, through: endedPause
        )
        return true
    }

    /// Every stream failure reported so far was checked by this resume and its source restarted,
    /// or left out when only legacy app audio could not restart. Its error is spent with it.
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
    /// The microphone is dead when its stream stopped, its engine is not running, or no raw buffer
    /// arrived within the stall threshold. The recorder fallback is restarted by `record()` at the
    /// end of the resume.
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
        guard !isRecorderFallbackActive else { return true }
        let engineStopped = !micCaptureController.isCaptureRunning()
        let stalled = isMicrophoneStalled()
        guard engineStopped || stalled else { return true }
        logger.notice(
            "Resume restarting engine microphone. engineStopped=\(engineStopped, privacy: .public) micStalled=\(stalled, privacy: .public)"
        )
        let restarted = await performMicRecovery(reason: .resume)
        guard restarted, isCurrentRecording(generation) else { return false }
        micRecoveryRetryTask?.cancel()
        micRecoveryRetryTask = nil
        captureRestartCount += 1
        return true
    }

    /// True when no raw microphone buffer arrived within the stall threshold, counted from the last
    /// buffer or from when the capture started, whichever is later.
    private func isMicrophoneStalled() -> Bool {
        guard let lastSign = [captureGates.mic.lastArrivalHostTime, micCaptureStartedAt].compactMap({ $0 }).max() else {
            return false
        }
        let now = hostNow().nanoseconds
        guard now > lastSign.nanoseconds else { return false }
        let silentSeconds = Double(now - lastSign.nanoseconds) / 1_000_000_000
        return silentSeconds > CaptureHealthMonitor.Configuration.default.stallThreshold
    }

    /// Restarts the legacy app stream if it stopped during the pause. Its absence alone is not a
    /// failure. A restart that fails leaves the recording without app audio from here on.
    private func restartDeadLegacyAppStream(generation: Int) async {
        guard let existing = appAudioCaptureSession, !existing.isStreamLive else { return }
        logger.notice("Resume restarting the app audio stream.")
        if !(await restartLegacyAppCapture(existing, generation: generation)) {
            logger.warning("App audio stream could not be restarted; the recording continues without app audio.")
        }
    }

    /// Replaces a stopped legacy app stream with a new one that writes into the same file.
    private func restartLegacyAppCapture(_ existing: AppAudioCaptureSession, generation: Int) async -> Bool {
        guard let appFileURL = activeAppFileURL, let processID = activeAppProcessID else { return false }
        await existing.stopStreamPreservingOutput()
        guard isCurrentRecording(generation), appAudioCaptureSession === existing else { return false }
        Self.sendStartedPauseMarkers(gates: captureGates, to: liveAudioContinuation, mic: false, app: true)

        let replacement = AppAudioCaptureSession(
            fileURL: appFileURL,
            processID: processID,
            onFirstBufferHostTime: { [weak self, clock = liveAudioClock] hostTime in
                clock?.observe(hostTime)
                Task { [weak self] in await self?.captureAppStartHostTimeIfNeeded(hostTime) }
            },
            liveAudioContinuation: liveAudioContinuation,
            streamer: existing.outputHandler.streamer,
            gate: captureGates.app,
            reusingPreparedOutput: existing.outputHandler.isOutputPrepared
        )
        let streamNumber = reportStreamFailures(of: replacement)
        do {
            try await startCaptureSession(.appAudio(replacement))
        } catch {
            logger.error("App audio restart failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard isCurrentRecording(generation), appAudioCaptureSession === existing else {
            await replacement.stopStreamPreservingOutput()
            return false
        }
        appAudioCaptureSession = replacement
        appStreamNumber = streamNumber
        captureRestartCount += 1
        logger.notice("App audio stream restarted (restart #\(self.captureRestartCount, privacy: .public)).")
        return true
    }

    /// Sends each source's marker for every pause that has started and that the source has not
    /// marked from its own buffers. For a capture replacement and the stop, which follow a drained
    /// or stopped delivery path, and the resume.
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
        routeRefusedMicDeviceID = nil
        // The recorder fallback writes the microphone file itself, so the engine can't take over
        // without writing over it.
        guard unifiedCaptureSession != nil || !isRecorderFallbackActive else {
            logger.notice("Mic retarget ignored: the recorder fallback keeps recording on the system input.")
            return
        }
        await requestMicRetarget(reason: .retarget)
    }

    // MARK: - Microphone transitions

    /// Why a microphone switch was requested. Logged only.
    private enum MicSwitchReason: String {
        case start, retarget, removal, preferredReturned, returnedUnderSameUID, hardwareChange
        case restart, configurationChange, retry, resume
    }

    /// Queues `body` behind every microphone transition queued before it, so target updates,
    /// unified restarts and engine recoveries run one at a time in request order.
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
        guard !isRecorderFallbackActive else { return }
        await applyMicTargetToEngine(generation: generation, reason: reason)
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

    /// Restarts engine capture on the target rule's device when it is not the device in use,
    /// including when the device in use was removed while the engine still reports running.
    private func applyMicTargetToEngine(generation: Int, reason: MicSwitchReason) async {
        let target = micCaptureTargetUID()
        guard resolveDeviceID(for: target) != currentCaptureDeviceID
                || currentCaptureDeviceUID != (resolveDeviceID(for: target) == nil ? nil : target)
        else {
            return
        }
        noteMicSwitchRequested(path: "engine", target: target, reason: reason)
        let didRecover = await recoverMicCapture(reason: reason)
        guard isCurrentRecording(generation) else { return }
        if didRecover {
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            return
        }
        scheduleMicRecoveryRetry()
    }

    /// Logs a switch and reports capture as switching until the new target's first buffer.
    private func noteMicSwitchRequested(path: String, target: String?, reason: MicSwitchReason) {
        isMicSwitchUnsettled = true
        logger.notice(
            "Mic switch requested: path=\(path, privacy: .public) target=\(target ?? "<default>", privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
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
    /// recording runs and under the recorder fallback, whose device is not known.
    func micCaptureTarget() -> MicCaptureTarget? {
        micTarget
    }

    /// The microphone being captured. Nil when no recording runs.
    func capturedMicrophone() -> CapturedMicrophone? {
        guard isRecordingValue else { return nil }
        if isRecorderFallbackActive { return .unknown }
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
        if let unified = unifiedCaptureSession {
            path = "unified"
            capturedUID = unified.currentMicDeviceUID
            capturedDeviceGone = capturedUID != nil && resolveDeviceID(for: capturedUID) == nil
        } else {
            path = "engine"
            capturedUID = currentCaptureDeviceUID
            capturedDeviceGone = capturedUID != nil && resolveDeviceID(for: capturedUID) != currentCaptureDeviceID
        }
        if capturedDeviceGone, let capturedUID {
            reason = .removal
            if loggedRemovedMicUID != capturedUID {
                loggedRemovedMicUID = capturedUID
                logger.notice(
                    "Captured mic removed: path=\(path, privacy: .public) device=\(capturedUID, privacy: .public)"
                )
            }
        }
        if let desired = desiredMicDeviceUID {
            if resolveDeviceID(for: desired) == nil {
                isPreferredMicAbsent = true
            } else if isPreferredMicAbsent {
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
        micRecoveryRetryTask?.cancel()
        micRecoveryRetryTask = nil
        deregisterMicHardwareListeners()
        stopMicCapture()
        micStreamer.close()
        audioRecorder = nil
        appAudioCaptureSession = nil
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
        routeRefusedMicDeviceID = nil
        currentCaptureDeviceID = nil
        currentCaptureDeviceUID = nil
        unifiedConfiguredMicDeviceID = nil
        unifiedStreamNumber = nil
        appStreamNumber = nil
        loggedRemovedMicUID = nil
        isPreferredMicAbsent = false
        micTarget = nil
        micTargetNumber += 1
        capturedMicDevice = nil
        isMicSwitchUnsettled = false
        micDeviceCapturedAtPause = nil
        micTransitionTail = nil
        micTransitionsInFlight = []
        queuedMicRetarget = nil
        micFileURL = nil
        isRecoveringMicCapture = false
        micRecoveryTask = nil
        restartInPlaceTask = nil
        resumeTask = nil
        micCaptureStartedAt = nil
#if DEBUG
        recorderFallbackActiveForTesting = false
#endif
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

    private func handleAudioEngineConfigurationChange() async {
        guard isRecordingValue else {
            return
        }
        // The recording path holds no `AVAudioEngine` under unified capture, so there is nothing
        // to restart. Recorded as an explicit exemption in `mic-capture-resilience` rather than
        // left implicit here.
        guard unifiedCaptureSession == nil else {
            return
        }
        // Match prior behavior: only react when engine-path capture is interrupted/stopped.
        guard !micCaptureController.isCaptureRunning() else {
            return
        }
        guard !isRecoveringMicCapture else {
            return
        }
        // Recorder fallback is naturally resilient to device changes.
        guard !isRecorderFallbackActive else {
            return
        }

        let generation = recordingGeneration
        let didRecover = await performMicRecovery(reason: .configurationChange)
        guard isCurrentRecording(generation) else { return }

        guard !didRecover else {
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            return
        }
        // Transient device-route/config transitions can fail an immediate restart.
        // Keep the session alive and continue retrying in the background.
        scheduleMicRecoveryRetry()
    }

    private func handleHardwareChange() async {
        guard isRecordingValue else {
            return
        }
        // The recorder fallback records the system input and ignores device changes (decision 10).
        guard unifiedCaptureSession != nil || !isRecorderFallbackActive else {
            return
        }
        // The device that refused explicit routing is tried again once it has left the list.
        if let routeRefusedMicDeviceID, routeRefusedMicDeviceID != resolveDeviceID(for: desiredMicDeviceUID) {
            self.routeRefusedMicDeviceID = nil
        }
        let reason = noteMicDeviceChanges()
        await requestMicRetarget(reason: reason)
    }

    private func startRecorderFallback(to fileURL: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try makeRecorderFallback(fileURL, settings)
        guard recorder.record() else {
            throw RecordingError.failedToStart("Unable to start recorder fallback.")
        }

        stopMicCapture()
        self.audioEngine = nil
        self.audioRecorder = recorder
        micTargetNumber += 1
        micTarget = nil
    }

    /// Starts engine capture on `desiredMicDeviceUID`, read after the last suspension so a newer
    /// request is the one installed. Throws `CaptureStartAbandoned` when the recording ended or was
    /// replaced during that suspension.
    private func startMicCapture(
        micFileURL: URL,
        liveContinuation: AsyncStream<LiveAudioChunk>.Continuation?
    ) async throws {
        let generation = recordingGeneration
        let vpEnabled = await voiceProcessingSetting()
        guard isCurrentOrStartingRecording(generation) else {
            throw CaptureStartAbandoned()
        }
        let targetUID = micCaptureTargetUID()
        let deviceID = resolveDeviceID(for: targetUID)
        try micCaptureController.startCapture(
            deviceID: deviceID,
            targetFormat: micTargetFormat,
            micFileURL: micFileURL,
            micStreamer: micStreamer,
            gate: captureGates.mic,
            voiceProcessingEnabled: vpEnabled,
            applyVoiceProcessing: { [weak self] inputNode, enabled in
                self?.applyVoiceProcessingIfNeeded(to: inputNode, enabled: enabled)
            },
            onFirstHostTime: { [weak self, clock = liveAudioClock] hostTime in
                clock?.observe(hostTime)
                Task { [weak self] in
                    await self?.captureMicStartHostTimeIfNeeded(hostTime)
                }
            },
            onBuffer: { output in
                switch output {
                case let .audio(samples, sampleRate, hostTime, rawHostTime):
                    liveContinuation?.yield(LiveAudioChunk(
                        samples: samples,
                        source: .mic,
                        sampleRate: sampleRate,
                        hostTime: hostTime,
                        rawHostTime: rawHostTime
                    ))
                case let .pauseMarker(number):
                    liveContinuation?.yield(.pauseMarker(number, source: .mic))
                }
            }
        )
        self.audioRecorder = nil
        self.audioEngine = nil
        self.currentCaptureDeviceID = deviceID
        self.currentCaptureDeviceUID = deviceID == nil ? nil : targetUID
        self.micFileURL = micFileURL
        self.micCaptureStartedAt = hostNow()
        publishMicTarget(currentCaptureDeviceUID)
    }

    private func stopMicCapture() {
        micCaptureController.stopCapture()
        currentCaptureDeviceID = nil
        currentCaptureDeviceUID = nil
        audioEngine = nil
    }

    private func teardownEngineForRecovery() {
        stopMicCapture()
    }

    /// Restarts engine capture after every transition queued before it, or waits for the restart
    /// already queued and returns its result.
    private func performMicRecovery(reason: MicSwitchReason) async -> Bool {
        if let micRecoveryTask {
            return await micRecoveryTask.value
        }
        let task = enqueueMicTransition { [weak self] in
            await self?.recoverMicCapture(reason: reason) ?? false
        }
        micRecoveryTask = task
        isRecoveringMicCapture = true
        let recovered = await task.value
        if micRecoveryTask == task {
            micRecoveryTask = nil
            isRecoveringMicCapture = false
        }
        return recovered
    }

    /// Stops engine capture and starts it on the target rule's device. Runs inside a queued
    /// transition; callers outside one use `performMicRecovery(reason:)`.
    private func recoverMicCapture(reason: MicSwitchReason) async -> Bool {
        guard let micFileURL else {
            return false
        }
        // The recorder fallback writes the microphone file itself; engine capture would write over
        // what it has saved.
        guard !isRecorderFallbackActive else {
            logger.notice("Mic recovery skipped: the recorder fallback holds the microphone file.")
            return false
        }
        teardownEngineForRecovery()
        Self.sendStartedPauseMarkers(gates: captureGates, to: liveAudioContinuation, mic: true, app: false)
        let recovered: Bool
        do {
            try await startMicCapture(micFileURL: micFileURL, liveContinuation: liveAudioContinuation)
            recovered = true
        } catch {
            recovered = false
        }
        let device = recovered ? currentCaptureDeviceUID : micCaptureTargetUID()
        logger.notice(
            "Engine mic recovery attempt: reason=\(reason.rawValue, privacy: .public) device=\(device ?? "<default>", privacy: .public) result=\(recovered ? "started" : "failed", privacy: .public)"
        )
        return recovered
    }

    private func scheduleMicRecoveryRetry() {
        guard isRecordingValue else {
            return
        }
        guard micRecoveryRetryTask == nil else {
            return
        }
        micRecoveryRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self else {
                    return
                }
                let shouldContinue = await self.retryMicCaptureFromRetryLoop()
                if !shouldContinue {
                    return
                }
            }
        }
    }

    private func retryMicCaptureFromRetryLoop() async -> Bool {
        guard isRecordingValue else {
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            return false
        }
        guard !isRecoveringMicCapture else {
            return true
        }
        let generation = recordingGeneration
        let didRecover = await performMicRecovery(reason: .retry)
        guard isCurrentRecording(generation) else { return false }
        if didRecover {
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            return false
        }
        return true
    }

    /// The one target rule for every capture transition: the preferred device while it is usable
    /// and has not refused the route, otherwise the device the recording started on while that is
    /// usable, otherwise the system default (`nil`). Callers read it after their last suspension.
    private func micCaptureTargetUID() -> String? {
        if let desiredDeviceID = resolveDeviceID(for: desiredMicDeviceUID),
           desiredDeviceID != routeRefusedMicDeviceID {
            return desiredMicDeviceUID
        }
        if let fallbackDeviceID = resolveDeviceID(for: fallbackMicDeviceUID),
           fallbackDeviceID != routeRefusedMicDeviceID {
            return fallbackMicDeviceUID
        }
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

    nonisolated func applyVoiceProcessingIfNeeded(to inputNode: AVAudioInputNode, enabled: Bool) {
        guard enabled else { return }
        do {
            if let setter = voiceProcessingPropertySetter {
                try setter(inputNode)
            } else {
                try inputNode.setVoiceProcessingEnabled(true)
            }
        } catch {
            logger.warning("Voice processing activation failed: \(error.localizedDescription, privacy: .public). Continuing without VP.")
        }
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
