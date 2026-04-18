import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import SwiftData

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
}

final class AVAudioEngineMicCaptureController: MicCaptureControlling {
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        micFileURL: URL,
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

        try micStreamer.prepare(url: micFileURL, format: targetFormat)

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

            micStreamer.write(buffer: outputBuffer)
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
    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let notificationCenter: NotificationCenter
    private let fileManager = FileManager.default
    private let mixdownCoordinator: RecordingMixdownCoordinator
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingService")
    private let appAudioSettings: AppAudioSettings
    private let hardware: AudioDeviceHardwareProviding
    private let micCaptureController: MicCaptureControlling
    // Injected for testing; nil uses the real setVoiceProcessingEnabled(_:)
    private let voiceProcessingPropertySetter: (@Sendable (AVAudioInputNode) throws -> Void)?

    private var audioEngine: AVAudioEngine?
    private let micStreamer = AudioFileStreamer()
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartedAt: Date?
    private var recordingCreatedAt: Date?
    private var recordingIdentifier: String?
    private var currentSessionID: UUID?
    private var appAudioURL: URL?
    private var micStartHostTime: UInt64?
    private var appStartHostTime: UInt64?
    private var desiredMicDeviceUID: String?
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
    private var pendingError: RecordingError?
    private let liveAudioStreamTuple: (stream: AsyncStream<([Float], AudioSource, Double)>, continuation: AsyncStream<([Float], AudioSource, Double)>.Continuation)
    // nonisolated(unsafe): written once in init on the actor; read only in deinit; lifetime matches the actor
    nonisolated(unsafe) private var engineConfigurationObserver: NSObjectProtocol?

    private var isRecordingValue = false
    private var audioLevelValue: Float = 0

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
        voiceProcessingPropertySetter: (@Sendable (AVAudioInputNode) throws -> Void)? = nil
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.appAudioSettings = appAudioSettings
        self.hardware = hardware
        self.micCaptureController = micCaptureController ?? AVAudioEngineMicCaptureController()
        self.notificationCenter = notificationCenter
        self.voiceProcessingPropertySetter = voiceProcessingPropertySetter
        self.mixdownCoordinator = RecordingMixdownCoordinator(
            workspaceService: workspaceService,
            modelContainer: modelContainer
        )
        self.liveAudioStreamTuple = AsyncStream<([Float], AudioSource, Double)>.makeStream()

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
        currentSessionID: UUID? = nil
    ) {
        self.isRecordingValue = isRecording
        self.recordingIdentifier = recordingIdentifier
        self.recordingWorkspaceRootURL = recordingWorkspaceRootURL
        self.recordingCreatedAt = recordingCreatedAt
        self.pendingTitle = pendingTitle
        self.currentSessionID = currentSessionID
    }
    #endif

    func audioLevel() async -> Float {
        var currentMax: Float = 0
        
        if let appAudioCaptureSession {
            currentMax = max(currentMax, appAudioCaptureSession.audioLevel)
        }
        
        if let audioRecorder {
            audioRecorder.updateMeters()
            let averagePower = audioRecorder.averagePower(forChannel: 0)
            if averagePower.isFinite {
                let normalized = powf(10, averagePower / 20)
                currentMax = max(currentMax, min(max(normalized, 0), 1))
            }
        }
        
        currentMax = max(currentMax, micStreamer.audioLevel)
        
        audioLevelValue = currentMax
        return currentMax
    }

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID? = nil,
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
        try await ensureMicrophonePermission()

        if !workspace.rootURL.startAccessingSecurityScopedResource() {
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
            self.micStartHostTime = nil
            self.appStartHostTime = nil
            self.micFileURL = micFileURL
            if let micDeviceID, micDeviceID != 0 {
                desiredMicDeviceUID = hardware.deviceUID(deviceID: micDeviceID)
            } else {
                desiredMicDeviceUID = nil
            }

            do {
                try await startMicCapture(
                    deviceUID: desiredMicDeviceUID,
                    micFileURL: micFileURL,
                    liveContinuation: liveAudioStreamTuple.continuation
                )
            } catch {
                try startRecorderFallback(to: micFileURL)
            }
            self.recordingStartedAt = Date()
            self.recordingCreatedAt = recordingCreatedAt
            self.recordingIdentifier = recordingIdentifier
            self.isRecordingValue = true
            self.audioLevelValue = 0
            self.pendingError = nil
            self.activeCapturedAppName = capturedAppName
            self.pendingTitle = title

            if let appProcessID {
                let session = AppAudioCaptureSession(
                    fileURL: appFileURL,
                    processID: appProcessID,
                    onFirstBufferHostTime: { [weak self] hostTime in
                        Task { [weak self] in
                            await self?.captureAppStartHostTimeIfNeeded(hostTime)
                        }
                    },
                    liveAudioContinuation: liveAudioStreamTuple.continuation
                )
                try await session.start()
                self.appAudioCaptureSession = session
                self.appAudioURL = appFileURL
            } else {
                self.appAudioCaptureSession = nil
                self.appAudioURL = nil
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
            return session.id
        } catch {
            stopMicCapture()
            audioRecorder?.stop()
            await appAudioCaptureSession?.stop()
            cleanupRecordingState()
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

        stopMicCapture()
        audioRecorder?.stop()
        micStreamer.close()
        await appAudioCaptureSession?.stop()
        appAudioCaptureSession = nil

        let startedAt = recordingStartedAt ?? recordingCreatedAt ?? Date()
        let createdAt = recordingCreatedAt ?? startedAt
        let stoppedAt = Date()
        let duration = max(0, stoppedAt.timeIntervalSince(startedAt))

        guard let recordingIdentifier, let recordingWorkspaceRootURL, let sessionID = currentSessionID else {
            cleanupRecordingState()
            return nil
        }

        let workspace = Workspace(rootURL: recordingWorkspaceRootURL)
        let captureFileURLs = Self.recordingFileURLs(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: recordingIdentifier
        )

        guard fileManager.fileExists(atPath: captureFileURLs.mic.path) else {
            cleanupRecordingState()
            return nil
        }
        let finalRecordingURLs: (mic: URL, app: URL?) = (
            captureFileURLs.mic,
            fileManager.fileExists(atPath: captureFileURLs.app.path) ? captureFileURLs.app : nil
        )

        logger.info(
            "Prepared recording session folder. mic=\(finalRecordingURLs.mic.path, privacy: .public) app=\(finalRecordingURLs.app?.path ?? "nil", privacy: .public)"
        )

        do {
            let micStartHostTime = self.micStartHostTime ?? self.appStartHostTime ?? 0
            let appStartHostTime = self.appStartHostTime
            let mixdownURL = finalRecordingURLs.mic.deletingLastPathComponent().appendingPathComponent("recording.m4a")

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
                cleanupRecordingState()
                return nil
            }
            session.duration = duration
            session.micAudioURL = finalRecordingURLs.mic.path
            session.appAudioURL = finalRecordingURLs.app?.path
            session.status = .recorded
            try context.save()

            // Release capture writer resources before background mixdown starts.
            cleanupRecordingState()

            Task { [weak self] in
                await self?.runMixdown(
                    sessionID: sessionID,
                    micURL: finalRecordingURLs.mic,
                    appURL: finalRecordingURLs.app,
                    mixdownURL: mixdownURL,
                    micStartHostTime: micStartHostTime,
                    appStartHostTime: appStartHostTime
                )
            }

            return sessionID
        } catch {
            cleanupRecordingState()
            return nil
        }
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }

    private func ensureMicrophonePermission() async throws(RecordingError) {
        try await RecordingPermissionService.ensureMicrophonePermission()
    }

    private func makeSessionTitle(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm"
        return "Recording \(formatter.string(from: createdAt))"
    }

    private func cleanupRecordingState() {
        stopMicCapture()
        micStreamer.close()
        audioRecorder = nil
        appAudioCaptureSession = nil
        appAudioURL = nil
        recordingStartedAt = nil
        recordingCreatedAt = nil
        recordingIdentifier = nil
        currentSessionID = nil
        activeCapturedAppName = nil
        pendingTitle = nil
        micStartHostTime = nil
        appStartHostTime = nil
        desiredMicDeviceUID = nil
        micFileURL = nil
        isRecoveringMicCapture = false
    }

    private func releaseRecordingScopeIfNeeded() {
        guard hasScopedRecordingAccess, let recordingWorkspaceRootURL else {
            return
        }

        recordingWorkspaceRootURL.stopAccessingSecurityScopedResource()
        hasScopedRecordingAccess = false
        self.recordingWorkspaceRootURL = nil
    }

    private func handleAudioEngineConfigurationChange() async {
        guard isRecordingValue else {
            return
        }
        guard !isRecoveringMicCapture else {
            return
        }
        // Recorder fallback is naturally resilient to device changes.
        guard audioRecorder == nil else {
            return
        }

        isRecoveringMicCapture = true
        let didRecover = await recoverMicCapture()
        isRecoveringMicCapture = false

        guard !didRecover else {
            return
        }

        micStreamer.close()
        audioRecorder?.stop()
        await appAudioCaptureSession?.stop()
        appAudioCaptureSession = nil
        cleanupRecordingState()
        audioLevelValue = 0
        isRecordingValue = false
        pendingError = .captureInterrupted
        releaseRecordingScopeIfNeeded()
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
        self.micFileURL = micFileURL
    }

    private func stopMicCapture() {
        micCaptureController.stopCapture()
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

    private func resolveDeviceID(for deviceUID: String?) -> AudioDeviceID? {
        guard let deviceUID, !deviceUID.isEmpty else {
            return nil
        }
        guard let allDevices = try? hardware.allDeviceIDs() else {
            return nil
        }
        return allDevices.first(where: { hardware.deviceUID(deviceID: $0) == deviceUID })
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

    func capturedHostTimes() -> (mic: UInt64?, app: UInt64?) {
        (micStartHostTime, appStartHostTime)
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
