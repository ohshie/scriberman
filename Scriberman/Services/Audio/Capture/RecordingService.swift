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
    case captureInterrupted
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
}

extension Notification.Name {
    static let appAudioCaptureAccessDenied = Notification.Name("appAudioCaptureAccessDenied")
}

protocol MicCaptureControlling: AnyObject {
    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        micFileURL: URL,
        micStreamer: AudioFileStreamer,
        voiceProcessingEnabled: Bool,
        applyVoiceProcessing: @Sendable (AVAudioInputNode, Bool) -> Void,
        onFirstHostTime: @escaping @Sendable (UInt64) -> Void,
        onBuffer: @escaping @Sendable ([Float], Double) -> Void
    ) throws
    func stopCapture()
    func retargetDevice(_ deviceID: AudioDeviceID?) throws
    func isCaptureRunning() -> Bool
}

final class AVAudioEngineMicCaptureController: MicCaptureControlling {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        micFileURL _: URL,
        micStreamer: AudioFileStreamer,
        voiceProcessingEnabled: Bool,
        applyVoiceProcessing: @Sendable (AVAudioInputNode, Bool) -> Void,
        onFirstHostTime: @escaping @Sendable (UInt64) -> Void,
        onBuffer: @escaping @Sendable ([Float], Double) -> Void
    ) throws {
        stopCapture()

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

        if inputFormat.sampleRate == targetFormat.sampleRate,
           inputFormat.channelCount == targetFormat.channelCount,
           inputFormat.commonFormat == targetFormat.commonFormat,
           inputFormat.isInterleaved == targetFormat.isInterleaved {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw RecordingError.failedToStart("Unable to create mic audio converter.")
            }
            self.converter = converter
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, audioTime in
            guard let self else {
                return
            }

            if audioTime.hostTime != 0 {
                onFirstHostTime(audioTime.hostTime)
            }

            let outputBuffer: AVAudioPCMBuffer
            if let converter = self.converter {
                guard let converted = self.convert(buffer, with: converter, to: targetFormat) else {
                    return
                }
                outputBuffer = converted
            } else {
                outputBuffer = buffer
            }

            let hostNanos: UInt64? = audioTime.hostTime != 0
                ? HostClock.nanoseconds(machTime: audioTime.hostTime)
                : nil
            micStreamer.write(buffer: outputBuffer, hostTimeNanos: hostNanos)
            let samples = AudioDownmixer.toMono(buffer: outputBuffer)
            onBuffer(samples, outputBuffer.format.sampleRate)
        }

        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    func stopCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
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

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let estimatedCapacity = max(AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32, 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedCapacity) else {
            return nil
        }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }
}

actor RecordingService: RecordingServiceProtocol {
    typealias PermissionChecker = @Sendable () async throws(RecordingError) -> Void
    typealias ScopedAccessStarter = @Sendable (URL) -> Bool
    typealias ScopedAccessStopper = @Sendable (URL) -> Void
    typealias ScreenCaptureSessionFactory = @Sendable () -> any ScreenCaptureSessionControlling

    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let notificationCenter: NotificationCenter
    private let fileManager = FileManager.default
    private let mixdownCoordinator: any RecordingMixdownCoordinating
    private let screenVideoMuxer: any ScreenVideoMuxing
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

    private var audioEngine: AVAudioEngine?
    private let micStreamer = AudioFileStreamer(label: "mic")
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartedAt: Date?
    private var recordingCreatedAt: Date?
    private var recordingIdentifier: String?
    private var currentSessionID: UUID?
    private var appAudioURL: URL?
    private var micStartHostTime: UInt64?
    private var appStartHostTime: UInt64?
    private var videoStartHostTime: UInt64?
    private var activeCaptureDisplayID: CGDirectDisplayID?
    private var desiredMicDeviceUID: String?
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
    private var screenCaptureSession: (any ScreenCaptureSessionControlling)?
    private var shouldSkipScreenMux = false
    private var pendingError: RecordingError?
    private var micRecoveryRetryTask: Task<Void, Never>?
    private let liveAudioStreamTuple: (stream: AsyncStream<([Float], AudioSource, Double)>, continuation: AsyncStream<([Float], AudioSource, Double)>.Continuation)
    // nonisolated(unsafe): written once in init on the actor; read only in deinit; lifetime matches the actor
    nonisolated(unsafe) private var engineConfigurationObserver: NSObjectProtocol?
    // nonisolated(unsafe): initialized once and used for CoreAudio C callback registration/removal lifecycle.
    nonisolated(unsafe) private var hardwarePropertyListener: AudioObjectPropertyListenerBlock?
    nonisolated(unsafe) private var hasRegisteredHardwareListeners = false
    private let hardwareListenerQueue: DispatchQueue

    private var isRecordingValue = false
    private var audioLevelValue: Float = 0
#if DEBUG
    private var recorderFallbackActiveForTesting = false
#endif

    func liveAudioStream() async -> AsyncStream<([Float], AudioSource, Double)> {
        liveAudioStreamTuple.stream
    }

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        appAudioSettings: AppAudioSettings,
        hardware: AudioDeviceHardwareProviding = CoreAudioDeviceHardware(),
        micCaptureController: MicCaptureControlling? = nil,
        notificationCenter: NotificationCenter = .default,
        mixdownCoordinator: (any RecordingMixdownCoordinating)? = nil,
        screenVideoMuxer: (any ScreenVideoMuxing)? = nil,
        permissionChecker: @escaping PermissionChecker = RecordingPermissionService.ensureMicrophonePermission,
        scopedAccessStarter: @escaping ScopedAccessStarter = { $0.startAccessingSecurityScopedResource() },
        scopedAccessStopper: @escaping ScopedAccessStopper = { $0.stopAccessingSecurityScopedResource() },
        screenCaptureSessionFactory: @escaping ScreenCaptureSessionFactory = { ScreenCaptureSession() },
        voiceProcessingPropertySetter: (@Sendable (AVAudioInputNode) throws -> Void)? = nil
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
        self.hardwareListenerQueue = DispatchQueue(label: "Scriberman.RecordingService.HardwareListeners")
        self.mixdownCoordinator = mixdownCoordinator ?? RecordingMixdownCoordinator(
            workspaceService: workspaceService,
            modelContainer: modelContainer
        )
        self.screenVideoMuxer = screenVideoMuxer ?? ScreenVideoMuxer(
            workspaceService: workspaceService,
            modelContainer: modelContainer
        )
        self.liveAudioStreamTuple = AsyncStream<([Float], AudioSource, Double)>.makeStream()
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
    func setRecordingStateForTesting(
        isRecording: Bool,
        recordingIdentifier: String? = nil,
        recordingWorkspaceRootURL: URL? = nil,
        recordingCreatedAt: Date? = nil,
        pendingTitle: String? = nil,
        currentSessionID: UUID? = nil,
        screenCaptureSession: (any ScreenCaptureSessionControlling)? = nil,
        videoStartHostTime: UInt64? = nil,
        shouldSkipScreenMux: Bool = false
    ) {
        self.isRecordingValue = isRecording
        self.recordingIdentifier = recordingIdentifier
        self.recordingWorkspaceRootURL = recordingWorkspaceRootURL
        self.recordingCreatedAt = recordingCreatedAt
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
        hasRecoveryRetryTask: Bool = false
    ) {
        self.desiredMicDeviceUID = desiredMicDeviceUID
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

    func audioLevels() async -> (mic: Float, app: Float) {
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

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID? = nil,
        captureDisplayID: CGDirectDisplayID? = nil,
        capturedAppName: String? = nil,
        appProcessID: pid_t? = nil,
        title: String? = nil
    ) async throws(RecordingError) -> UUID {
        guard !isRecordingValue else {
            throw RecordingError.alreadyRecording
        }

        do {
            _ = try await workspaceService.requireWritableWorkspace()
        } catch {
            throw RecordingError.invalidWorkspaceAccess
        }
        try await permissionChecker()

        if !scopedAccessStarter(workspace.rootURL) {
            throw RecordingError.invalidWorkspaceAccess
        }

        hasScopedRecordingAccess = true
        recordingWorkspaceRootURL = workspace.rootURL

        do {
            try fileManager.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
            let recordingCreatedAt = Date()
            let recordingIdentifier = UUID().uuidString
            let recordingFolderURL = Self.recordingFolderURL(
                in: workspace,
                createdAt: recordingCreatedAt,
                recordingIdentifier: recordingIdentifier
            )
            try fileManager.createDirectory(at: recordingFolderURL, withIntermediateDirectories: true)

            let fileURLs = Self.recordingFileURLs(
                in: workspace,
                createdAt: recordingCreatedAt,
                recordingIdentifier: recordingIdentifier
            )
            let micFileURL = fileURLs.mic
            let appFileURL = fileURLs.app
            let screenTmpVideoURL = RecordingFileLayout.screenTmpVideoURL(
                in: workspace,
                createdAt: recordingCreatedAt,
                recordingIdentifier: recordingIdentifier
            )
            self.micStartHostTime = nil
            self.appStartHostTime = nil
            self.videoStartHostTime = nil
            self.activeCaptureDisplayID = captureDisplayID
            self.shouldSkipScreenMux = false
            self.micFileURL = micFileURL
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            if let micDeviceID, micDeviceID != 0 {
                desiredMicDeviceUID = hardware.deviceUID(deviceID: micDeviceID)
            } else {
                desiredMicDeviceUID = nil
            }
            try micStreamer.prepare(url: micFileURL, format: micTargetFormat)

            if let appProcessID {
                let appSession = AppAudioCaptureSession(
                    fileURL: appFileURL,
                    processID: appProcessID,
                    onFirstBufferHostTime: { [weak self] hostTime in
                        Task { [weak self] in
                            await self?.captureAppStartHostTimeIfNeeded(hostTime)
                        }
                    },
                    liveAudioContinuation: liveAudioStreamTuple.continuation
                )
                try await appSession.start()
                self.appAudioCaptureSession = appSession
                self.appAudioURL = appFileURL
            } else {
                self.appAudioCaptureSession = nil
                self.appAudioURL = nil
            }

            do {
                try await startMicCapture(
                    deviceUID: desiredMicDeviceUID,
                    micFileURL: micFileURL,
                    liveContinuation: liveAudioStreamTuple.continuation
                )
            } catch {
                // Bluetooth/external devices can fail explicit routing on some setups.
                // Retry with the default input device so the live stream path stays active.
                if desiredMicDeviceUID != nil {
                    logger.warning(
                        "Mic capture failed for selected device; retrying on default input. error=\(error.localizedDescription, privacy: .public)"
                    )
                    desiredMicDeviceUID = nil
                    do {
                        try await startMicCapture(
                            deviceUID: nil,
                            micFileURL: micFileURL,
                            liveContinuation: liveAudioStreamTuple.continuation
                        )
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
            self.recordingStartedAt = Date()
            self.recordingCreatedAt = recordingCreatedAt
            self.recordingIdentifier = recordingIdentifier
            self.isRecordingValue = true
            self.audioLevelValue = 0
            self.pendingError = nil
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
                        videoURL: screenTmpVideoURL
                    )
                    self.screenCaptureSession = screenCaptureSession
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
            let context = ModelContext(modelContainer)
            context.insert(session)
            try context.save()
            self.currentSessionID = session.id
            registerMicHardwareListeners()
            return session.id
        } catch {
            stopMicCapture()
            audioRecorder?.stop()
            await appAudioCaptureSession?.stop()
            await cleanupRecordingState()
            releaseRecordingScopeIfNeeded()
            throw RecordingError.failedToStart(error.localizedDescription)
        }
    }

    func stopRecording() async -> UUID? {
        guard isRecordingValue else {
            return nil
        }

        defer {
            audioLevelValue = 0
            isRecordingValue = false
            releaseRecordingScopeIfNeeded()
        }

        deregisterMicHardwareListeners()
        stopMicCapture()
        audioRecorder?.stop()
        micStreamer.close()
        await appAudioCaptureSession?.stop()
        appAudioCaptureSession = nil
        let activeScreenCaptureSession = screenCaptureSession
        screenCaptureSession = nil
        await activeScreenCaptureSession?.stop()
        captureVideoStartHostTimeIfNeeded(activeScreenCaptureSession?.videoStartHostTime)

        let startedAt = recordingStartedAt ?? recordingCreatedAt ?? Date()
        let createdAt = recordingCreatedAt ?? startedAt
        let stoppedAt = Date()
        let duration = max(0, stoppedAt.timeIntervalSince(startedAt))

        guard let recordingIdentifier, let recordingWorkspaceRootURL, let sessionID = currentSessionID else {
            await cleanupRecordingState()
            return nil
        }

        let workspace = Workspace(rootURL: recordingWorkspaceRootURL)
        let captureFileURLs = Self.recordingFileURLs(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: recordingIdentifier
        )

        guard fileManager.fileExists(atPath: captureFileURLs.mic.path) else {
            await cleanupRecordingState()
            return nil
        }
        let finalRecordingURLs: (mic: URL, app: URL?) = (
            captureFileURLs.mic,
            fileManager.fileExists(atPath: captureFileURLs.app.path) ? captureFileURLs.app : nil
        )
        let screenTmpVideoURL = RecordingFileLayout.screenTmpVideoURL(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: recordingIdentifier
        )
        let finalScreenVideoURL = RecordingFileLayout.screenVideoURL(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: recordingIdentifier
        )

        logger.info(
            "Prepared recording session folder. mic=\(finalRecordingURLs.mic.path, privacy: .public) app=\(finalRecordingURLs.app?.path ?? "nil", privacy: .public)"
        )

        do {
            let micStartHostTime = self.micStartHostTime ?? self.appStartHostTime ?? 0
            let appStartHostTime = self.appStartHostTime
            let videoStartHostTime = shouldSkipScreenMux ? nil : self.videoStartHostTime
            let mixdownURL = finalRecordingURLs.mic.deletingLastPathComponent().appendingPathComponent("recording.m4a")
            let shouldRunScreenMux = videoStartHostTime != nil && fileManager.fileExists(atPath: screenTmpVideoURL.path)

            if self.micStartHostTime == nil {
                logger.warning("Mic start host time missing for session \(sessionID, privacy: .public); using fallback for mixdown alignment.")
            }
            logger.info(
                "Scheduling mixdown for session \(sessionID, privacy: .public). micStart=\(micStartHostTime, privacy: .public) appStart=\(appStartHostTime ?? 0, privacy: .public) hasApp=\(finalRecordingURLs.app != nil, privacy: .public)"
            )

            let context = ModelContext(modelContainer)
            var descriptor = FetchDescriptor<RecordingSession>()
            descriptor.fetchLimit = 1_000
            guard let sessions = try? context.fetch(descriptor),
                  let session = sessions.first(where: { $0.id == sessionID })
            else {
                await cleanupRecordingState()
                return nil
            }
            session.duration = duration
            session.micAudioURL = finalRecordingURLs.mic.path
            session.appAudioURL = finalRecordingURLs.app?.path
            session.status = .recorded
            if activeCaptureDisplayID != nil && !shouldRunScreenMux {
                session.screenCaptureWarning = "Screen recording failed — the display may have been off, disconnected, or not capturable."
                logger.warning(
                    "Screen capture was requested but produced no video. displayID=\(self.activeCaptureDisplayID ?? 0, privacy: .public) shouldSkipScreenMux=\(self.shouldSkipScreenMux, privacy: .public) videoStartHostTime=\(self.videoStartHostTime != nil ? "set" : "nil", privacy: .public)"
                )
            }
            try context.save()

            // Release capture writer resources before background mixdown starts.
            await cleanupRecordingState(deleteScreenTmpVideo: !shouldRunScreenMux)

            let timelineEnabled = AudioSyncConfig.isTimelineMixdownEnabled
            let audioAnchorHostTime = appStartHostTime.map { min(micStartHostTime, $0) } ?? micStartHostTime

            Task { [weak self] in
                await self?.runMixdown(
                    sessionID: sessionID,
                    micURL: finalRecordingURLs.mic,
                    appURL: finalRecordingURLs.app,
                    mixdownURL: mixdownURL,
                    micStartHostTime: micStartHostTime,
                    appStartHostTime: appStartHostTime
                )

                // Timeline path: mux the drift-corrected mixdown audio (produced above) into
                // the video, so the video gets the same aligned audio and we avoid the
                // raw-WAV delete race.
                if timelineEnabled, let videoStartHostTime, shouldRunScreenMux {
                    let request = ScreenVideoMuxRequest(
                        sessionID: sessionID,
                        screenTmpURL: screenTmpVideoURL,
                        screenVideoURL: finalScreenVideoURL,
                        micURL: finalRecordingURLs.mic,
                        appURL: finalRecordingURLs.app,
                        micStartHostTime: micStartHostTime,
                        appStartHostTime: appStartHostTime,
                        videoStartHostTime: videoStartHostTime,
                        timelineAudioURL: mixdownURL,
                        audioAnchorHostTime: audioAnchorHostTime
                    )
                    await self?.screenVideoMuxer.runMux(request: request)
                }
            }

            // Legacy path: mux the raw mic/app tracks concurrently (unchanged default behavior).
            if !timelineEnabled, let videoStartHostTime, shouldRunScreenMux {
                let request = ScreenVideoMuxRequest(
                    sessionID: sessionID,
                    screenTmpURL: screenTmpVideoURL,
                    screenVideoURL: finalScreenVideoURL,
                    micURL: finalRecordingURLs.mic,
                    appURL: finalRecordingURLs.app,
                    micStartHostTime: micStartHostTime,
                    appStartHostTime: appStartHostTime,
                    videoStartHostTime: videoStartHostTime
                )
                Task { [weak self] in
                    await self?.screenVideoMuxer.runMux(request: request)
                }
            }

            return sessionID
        } catch {
            await cleanupRecordingState()
            return nil
        }
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }

    func retargetMic(desiredDeviceUID: String?) async {
        guard isRecordingValue else {
            return
        }
        self.desiredMicDeviceUID = desiredDeviceUID
        guard !isRecoveringMicCapture else {
            return
        }
        isRecoveringMicCapture = true
        let didRecover = await recoverMicCapture()
        isRecoveringMicCapture = false
        if didRecover {
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            return
        }
        scheduleMicRecoveryRetry()
    }

    private func makeSessionTitle(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm"
        return "Recording \(formatter.string(from: createdAt))"
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
        if let screenCaptureSession {
            await screenCaptureSession.stop()
        }
        self.screenCaptureSession = nil
        if deleteScreenTmpVideo, let screenTmpURL, fileManager.fileExists(atPath: screenTmpURL.path) {
            try? fileManager.removeItem(at: screenTmpURL)
        }
        appAudioURL = nil
        recordingStartedAt = nil
        recordingCreatedAt = nil
        recordingIdentifier = nil
        currentSessionID = nil
        activeCapturedAppName = nil
        pendingTitle = nil
        micStartHostTime = nil
        appStartHostTime = nil
        videoStartHostTime = nil
        shouldSkipScreenMux = false
        activeCaptureDisplayID = nil
        desiredMicDeviceUID = nil
        currentCaptureDeviceID = nil
        micFileURL = nil
        isRecoveringMicCapture = false
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
        guard let recordingWorkspaceRootURL,
              let recordingCreatedAt,
              let recordingIdentifier
        else {
            return nil
        }
        return RecordingFileLayout.screenTmpVideoURL(
            in: Workspace(rootURL: recordingWorkspaceRootURL),
            createdAt: recordingCreatedAt,
            recordingIdentifier: recordingIdentifier
        )
    }

    private func handleAudioEngineConfigurationChange() async {
        guard isRecordingValue else {
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
#if DEBUG
        let isRecorderFallbackActive = audioRecorder != nil || recorderFallbackActiveForTesting
#else
        let isRecorderFallbackActive = audioRecorder != nil
#endif
        guard !isRecorderFallbackActive else {
            return
        }

        isRecoveringMicCapture = true
        let didRecover = await recoverMicCapture()
        isRecoveringMicCapture = false

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
        guard !isRecoveringMicCapture else {
            return
        }
        guard audioRecorder == nil else {
            return
        }
        guard let desiredMicDeviceUID,
              let desiredDeviceID = resolveDeviceID(for: desiredMicDeviceUID),
              currentCaptureDeviceID != desiredDeviceID
        else {
            return
        }

        isRecoveringMicCapture = true
        let didRecover = await recoverMicCapture()
        isRecoveringMicCapture = false
        if didRecover {
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            return
        }
        scheduleMicRecoveryRetry()
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

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw RecordingError.failedToStart("Unable to start recorder fallback.")
        }

        stopMicCapture()
        self.audioEngine = nil
        self.audioRecorder = recorder
    }

    private func startMicCapture(
        deviceUID: String?,
        micFileURL: URL,
        liveContinuation: AsyncStream<([Float], AudioSource, Double)>.Continuation
    ) async throws {
        let vpEnabled = await MainActor.run { appAudioSettings.voiceProcessingEnabled }
        let deviceID = resolveDeviceID(for: deviceUID)
        try micCaptureController.startCapture(
            deviceID: deviceID,
            targetFormat: micTargetFormat,
            micFileURL: micFileURL,
            micStreamer: micStreamer,
            voiceProcessingEnabled: vpEnabled,
            applyVoiceProcessing: { [weak self] inputNode, enabled in
                self?.applyVoiceProcessingIfNeeded(to: inputNode, enabled: enabled)
            },
            onFirstHostTime: { [weak self] hostTime in
                Task { [weak self] in
                    await self?.captureMicStartHostTimeIfNeeded(hostTime)
                }
            },
            onBuffer: { samples, sampleRate in
                liveContinuation.yield((samples, .mic, sampleRate))
            }
        )
        self.audioRecorder = nil
        self.audioEngine = nil
        self.currentCaptureDeviceID = deviceID
        self.micFileURL = micFileURL
    }

    private func stopMicCapture() {
        micCaptureController.stopCapture()
        currentCaptureDeviceID = nil
        audioEngine = nil
    }

    private func teardownEngineForRecovery() {
        stopMicCapture()
    }

    private func recoverMicCapture() async -> Bool {
        guard let micFileURL else {
            return false
        }
        teardownEngineForRecovery()
        do {
            try await startMicCapture(
                deviceUID: desiredMicDeviceUID,
                micFileURL: micFileURL,
                liveContinuation: liveAudioStreamTuple.continuation
            )
            return true
        } catch {
            return false
        }
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
        isRecoveringMicCapture = true
        let didRecover = await recoverMicCapture()
        isRecoveringMicCapture = false
        if didRecover {
            micRecoveryRetryTask?.cancel()
            micRecoveryRetryTask = nil
            return false
        }
        return true
    }

    private func resolveDeviceID(for deviceUID: String?) -> AudioDeviceID? {
        guard let deviceUID, !deviceUID.isEmpty else {
            return nil
        }
        guard let allDevices = try? hardware.allDeviceIDs() else {
            return nil
        }
        return allDevices.first(where: { hardware.deviceUID(deviceID: $0) == deviceUID })
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

    func captureMicStartHostTimeIfNeeded(_ hostTime: UInt64) {
        guard micStartHostTime == nil else {
            return
        }
        micStartHostTime = hostTime
    }

    func captureAppStartHostTimeIfNeeded(_ hostTime: UInt64) {
        guard appStartHostTime == nil else {
            return
        }
        appStartHostTime = hostTime
    }

    func captureVideoStartHostTimeIfNeeded(_ hostTime: UInt64?) {
        guard videoStartHostTime == nil, let hostTime else {
            return
        }
        videoStartHostTime = hostTime
    }

    func capturedHostTimes() -> (mic: UInt64?, app: UInt64?, video: UInt64?) {
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
        micStartHostTime: UInt64,
        appStartHostTime: UInt64?
    ) async {
        await mixdownCoordinator.runMixdown(
            sessionID: sessionID,
            micURL: micURL,
            appURL: appURL,
            mixdownURL: mixdownURL,
            micStartHostTime: micStartHostTime,
            appStartHostTime: appStartHostTime
        )
    }

}

extension RecordingService {
    static func recordingFolderURL(
        in workspace: Workspace,
        createdAt: Date,
        recordingIdentifier: String
    ) -> URL {
        RecordingFileLayout.recordingFolderURL(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: recordingIdentifier
        )
    }

    static func recordingFileURLs(
        in workspace: Workspace,
        createdAt: Date,
        recordingIdentifier: String
    ) -> (mic: URL, app: URL) {
        RecordingFileLayout.recordingFileURLs(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: recordingIdentifier
        )
    }

    static func folderName(createdAt: Date, recordingIdentifier: String) -> String {
        RecordingFileLayout.folderName(createdAt: createdAt, recordingIdentifier: recordingIdentifier)
    }

}
