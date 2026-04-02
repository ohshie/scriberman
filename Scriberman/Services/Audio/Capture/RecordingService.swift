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

actor RecordingService: RecordingServiceProtocol {
    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let notificationCenter: NotificationCenter
    private let fileManager = FileManager.default
    private let mixdownService = AudioMixdownService()
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingService")

    private var audioEngine: AVAudioEngine?
    private let micStreamer = AudioFileStreamer()
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartedAt: Date?
    private var recordingIdentifier: String?
    private var appAudioURL: URL?
    private var micStartHostTime: UInt64?
    private var appStartHostTime: UInt64?
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
        notificationCenter: NotificationCenter = .default
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.notificationCenter = notificationCenter
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
        pendingTitle: String? = nil
    ) {
        self.isRecordingValue = isRecording
        self.recordingIdentifier = recordingIdentifier
        self.recordingWorkspaceRootURL = recordingWorkspaceRootURL
        self.pendingTitle = pendingTitle
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
    ) async throws(RecordingError) {
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
            try fileManager.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)

            let recordingIdentifier = UUID().uuidString
            let fileURLs = Self.recordingFileURLs(in: workspace)
            let micFileURL = fileURLs.mic
            let appFileURL = fileURLs.app
            self.micStartHostTime = nil
            self.appStartHostTime = nil

            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode

            if let micDeviceID, micDeviceID != 0 {
                guard let inputAudioUnit = inputNode.audioUnit else {
                    throw RecordingError.failedToStart("Audio input unit is unavailable.")
                }

                var targetDeviceID = micDeviceID
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
                    // On some sandboxed/runtime combinations explicit mic routing fails; continue on default input.
                }
            }

            let inputFormat = inputNode.inputFormat(forBus: 0)
            if isValidTapFormat(inputFormat) {
                do {
                    try micStreamer.prepare(url: micFileURL, format: inputFormat)

                    inputNode.removeTap(onBus: 0)
                    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, audioTime in
                        if audioTime.hostTime != 0 {
                            Task { [weak self] in
                                await self?.captureMicStartHostTimeIfNeeded(audioTime.hostTime)
                            }
                        }

                        self?.micStreamer.write(buffer: buffer)
                        let samples = AudioDownmixer.toMono(buffer: buffer)
                        self?.liveAudioStreamTuple.continuation.yield((samples, .mic, buffer.format.sampleRate))
                    }

                    audioEngine.prepare()
                    try audioEngine.start()

                    self.audioEngine = audioEngine
                    self.audioRecorder = nil
                } catch {
                    inputNode.removeTap(onBus: 0)
                    audioEngine.stop()
                    try startRecorderFallback(to: micFileURL)
                }
            } else {
                try startRecorderFallback(to: micFileURL)
            }
            self.recordingStartedAt = Date()
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
        } catch {
            audioEngine?.inputNode.removeTap(onBus: 0)
            audioEngine?.stop()
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

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioRecorder?.stop()
        micStreamer.close()
        await appAudioCaptureSession?.stop()
        appAudioCaptureSession = nil

        let startedAt = recordingStartedAt ?? Date()
        let createdAt = Date()
        let duration = max(0, createdAt.timeIntervalSince(startedAt))

        guard let recordingIdentifier, let recordingWorkspaceRootURL else {
            cleanupRecordingState()
            return nil
        }

        let workspace = Workspace(rootURL: recordingWorkspaceRootURL)
        let finalRecordingURLs: (mic: URL, app: URL?)
        do {
            finalRecordingURLs = try Self.promoteTmpRecordingFolder(
                in: workspace,
                createdAt: createdAt,
                recordingIdentifier: recordingIdentifier,
                fileManager: fileManager
            )
        } catch {
            cleanupRecordingState()
            return nil
        }

        logger.info(
            "Prepared recording session folder. mic=\(finalRecordingURLs.mic.path, privacy: .public) app=\(finalRecordingURLs.app?.path ?? "nil", privacy: .public)"
        )

        let session = RecordingSession(
            createdAt: createdAt,
            duration: duration,
            micAudioURL: finalRecordingURLs.mic.path,
            appAudioURL: finalRecordingURLs.app?.path,
            title: pendingTitle ?? makeSessionTitle(createdAt: createdAt),
            capturedAppName: activeCapturedAppName,
            status: .recorded
        )

        do {
            let sessionID = session.id
            let persistentID = session.id
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
            context.insert(session)
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

            return persistentID
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
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }

            guard granted else {
                throw RecordingError.microphoneDenied
            }
        case .restricted, .denied:
            throw RecordingError.microphoneDenied
        @unknown default:
            throw RecordingError.microphoneDenied
        }
    }

    private func makeSessionTitle(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm"
        return "Recording \(formatter.string(from: createdAt))"
    }

    private func cleanupRecordingState() {
        audioEngine = nil
        micStreamer.close()
        audioRecorder = nil
        appAudioCaptureSession = nil
        appAudioURL = nil
        recordingStartedAt = nil
        recordingIdentifier = nil
        activeCapturedAppName = nil
        pendingTitle = nil
        micStartHostTime = nil
        appStartHostTime = nil
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
        guard let audioEngine else {
            return
        }
        guard !audioEngine.isRunning else {
            return
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
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

        self.audioEngine = nil
        self.audioRecorder = recorder
    }

    private func isValidTapFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite && format.sampleRate > 0 && format.channelCount > 0
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

    func runMixdown(
        sessionID: UUID,
        micURL: URL,
        appURL: URL?,
        mixdownURL: URL,
        micStartHostTime: UInt64,
        appStartHostTime: UInt64?
    ) async {
        var scopedWorkspaceRoot: URL?
        var didStartScopedAccess = false
        if let workspace = await workspaceService.currentWorkspace(),
           micURL.path.hasPrefix(workspace.rootURL.path) {
            scopedWorkspaceRoot = workspace.rootURL
            didStartScopedAccess = workspace.rootURL.startAccessingSecurityScopedResource()
            logger.info(
                "Mixdown workspace scope for session \(sessionID, privacy: .public): started=\(didStartScopedAccess, privacy: .public) root=\(workspace.rootURL.path, privacy: .public)"
            )
        }
        defer {
            if didStartScopedAccess {
                scopedWorkspaceRoot?.stopAccessingSecurityScopedResource()
            }
        }

        logger.info(
            "Mixdown started for session \(sessionID, privacy: .public). mic=\(micURL.path, privacy: .public) app=\(appURL?.path ?? "nil", privacy: .public) out=\(mixdownURL.path, privacy: .public)"
        )
        let micSize = (try? fileManager.attributesOfItem(atPath: micURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        let appSize = appURL.flatMap { url in
            (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        } ?? -1
        logger.info(
            "Mixdown input sizes for session \(sessionID, privacy: .public). micBytes=\(micSize, privacy: .public) appBytes=\(appSize, privacy: .public)"
        )
        logger.info(
            "Mixdown timing for session \(sessionID, privacy: .public). micStart=\(micStartHostTime, privacy: .public) appStart=\(appStartHostTime ?? 0, privacy: .public)"
        )
        do {
            try await mixdownService.mix(
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: micStartHostTime,
                appStartHostTime: appStartHostTime,
                into: mixdownURL
            )
        } catch {
            logger.error("Mixdown failed for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let existsAfterMix = fileManager.fileExists(atPath: mixdownURL.path)
        logger.info(
            "Mixdown finished for session \(sessionID, privacy: .public). outputExists=\(existsAfterMix, privacy: .public) path=\(mixdownURL.path, privacy: .public)"
        )

        do {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<RecordingSession>()
            let sessions = try context.fetch(descriptor)
            var persistedSession: RecordingSession?
            for session in sessions where session.id == sessionID {
                persistedSession = session
                break
            }
            guard let persistedSession else {
                logger.error("Mixdown succeeded but session \(sessionID, privacy: .public) was not found for persistence update.")
                return
            }

            persistedSession.mixdownURL = mixdownURL.path
            try context.save()
            logger.info("Persisted mixdownURL for session \(sessionID, privacy: .public): \(mixdownURL.path, privacy: .public)")
        } catch {
            logger.error("Failed to persist mixdown URL for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

}

extension RecordingService {
    static func recordingFileURLs(in workspace: Workspace) -> (mic: URL, app: URL) {
        (
            workspace.tmpRecordingURL.appendingPathComponent("mic.wav"),
            workspace.tmpRecordingURL.appendingPathComponent("app.wav")
        )
    }

    static func folderName(createdAt: Date, recordingIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd 'at' HH-mm"
        let suffix = String(recordingIdentifier.suffix(2))
        return "Recording \(formatter.string(from: createdAt)) \(suffix)"
    }

    static func promoteTmpRecordingFolder(
        in workspace: Workspace,
        createdAt: Date,
        recordingIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> (mic: URL, app: URL?) {
        let folderName = folderName(createdAt: createdAt, recordingIdentifier: recordingIdentifier)
        let namedFolderURL = workspace.recordingsURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.moveItem(at: workspace.tmpRecordingURL, to: namedFolderURL)

        let micURL = namedFolderURL.appendingPathComponent("mic.wav")
        let appURL = namedFolderURL.appendingPathComponent("app.wav")
        let finalAppURL = fileManager.fileExists(atPath: appURL.path) ? appURL : nil
        return (micURL, finalAppURL)
    }
}
