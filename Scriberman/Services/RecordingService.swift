import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
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

actor RecordingService: RecordingServiceProtocol {
    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let notificationCenter: NotificationCenter
    private let fileManager = FileManager.default
    private let mixdownService = AudioMixdownService()
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingService")

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var audioRecorder: AVAudioRecorder?
    private var recordingStartedAt: Date?
    private var recordingIdentifier: String?
    private var appAudioURL: URL?
    private var micStartHostTime: UInt64?
    private var appStartHostTime: UInt64?
    private var hasScopedRecordingAccess = false
    private var recordingWorkspaceRootURL: URL?
    private var activeCapturedAppName: String?
    private var appAudioCaptureSession: AppAudioCaptureSession?
    private var pendingError: RecordingError?
    private var engineConfigurationObserver: NSObjectProtocol?

    private var isRecordingValue = false
    private var audioLevelValue: Float = 0

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        notificationCenter: NotificationCenter = .default
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.notificationCenter = notificationCenter

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

    func audioLevel() async -> Float {
        if let appAudioCaptureSession {
            let appLevel = appAudioCaptureSession.audioLevel
            audioLevelValue = max(audioLevelValue, appLevel)
        }
        if let audioRecorder {
            audioRecorder.updateMeters()
            let averagePower = audioRecorder.averagePower(forChannel: 0)
            if averagePower.isFinite {
                let normalized = powf(10, averagePower / 20)
                audioLevelValue = min(max(normalized, 0), 1)
            }
        }
        return audioLevelValue
    }

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID? = nil,
        capturedAppName: String? = nil,
        appProcessID: pid_t? = nil
    ) async throws {
        guard !isRecordingValue else {
            throw RecordingError.alreadyRecording
        }

        _ = try await workspaceService.requireWritableWorkspace()
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
                    let audioFile = try AVAudioFile(
                        forWriting: micFileURL,
                        settings: inputFormat.settings,
                        commonFormat: inputFormat.commonFormat,
                        interleaved: inputFormat.isInterleaved
                    )

                    inputNode.removeTap(onBus: 0)
                    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, audioTime in
                        if audioTime.hostTime != 0 {
                            Task { [weak self] in
                                await self?.captureMicStartHostTimeIfNeeded(audioTime.hostTime)
                            }
                        }

                        do {
                            try audioFile.write(from: buffer)
                        } catch {
                            return
                        }

                        Task { [weak self] in
                            await self?.updateAudioLevel(from: buffer)
                        }
                    }

                    audioEngine.prepare()
                    try audioEngine.start()

                    self.audioEngine = audioEngine
                    self.audioFile = audioFile
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

            if let appProcessID {
                let session = AppAudioCaptureSession(
                    fileURL: appFileURL,
                    processID: appProcessID,
                    onFirstBufferHostTime: { [weak self] hostTime in
                        Task { [weak self] in
                            await self?.captureAppStartHostTimeIfNeeded(hostTime)
                        }
                    }
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

    func stopRecording() async -> RecordingSession? {
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
        await appAudioCaptureSession?.stop()
        appAudioCaptureSession = nil
        if #available(macOS 15.0, *) {
            audioFile?.close()
            logger.info("Closed mic AVAudioFile writer before session folder promotion.")
        }

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
            title: makeSessionTitle(createdAt: createdAt),
            capturedAppName: activeCapturedAppName,
            status: .recorded
        )

        do {
            let sessionID = session.id
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

            return session
        } catch {
            cleanupRecordingState()
            return nil
        }
    }

    func consumePendingError() async -> RecordingError? {
        defer { pendingError = nil }
        return pendingError
    }

    private func ensureMicrophonePermission() async throws {
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

    private func updateAudioLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            audioLevelValue = 0
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            audioLevelValue = 0
            return
        }

        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for sampleIndex in 0..<frameCount {
                let sample = samples[sampleIndex]
                sumSquares += sample * sample
            }
        }

        let meanSquare = sumSquares / Float(frameCount * max(channelCount, 1))
        let rms = sqrt(meanSquare)
        audioLevelValue = min(max(rms, 0), 1)
    }

    private func makeSessionTitle(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM dd, HH:mm"
        return "Recording \(formatter.string(from: createdAt))"
    }

    private func cleanupRecordingState() {
        audioEngine = nil
        audioFile = nil
        audioRecorder = nil
        appAudioCaptureSession = nil
        appAudioURL = nil
        recordingStartedAt = nil
        recordingIdentifier = nil
        activeCapturedAppName = nil
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
        self.audioFile = nil
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
            var descriptor = FetchDescriptor<RecordingSession>(
                predicate: #Predicate { $0.id == sessionID }
            )
            descriptor.fetchLimit = 1
            guard let persistedSession = try context.fetch(descriptor).first else {
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

final class AppAudioCaptureSession {
    private let fileURL: URL
    private let processID: pid_t
    private let outputHandler = AppAudioStreamOutputHandler()
    private let sampleQueue = DispatchQueue(label: "com.scriberman.app-audio.stream")
    private var stream: SCStream?

    var audioLevel: Float {
        outputHandler.audioLevel
    }

    init(
        fileURL: URL,
        processID: pid_t,
        onFirstBufferHostTime: (@Sendable (UInt64) -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.processID = processID
        outputHandler.onFirstBufferHostTime = onFirstBufferHostTime
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
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
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
}

final class AppAudioStreamOutputHandler: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var fileURL: URL?
    private var audioFile: AVAudioFile?
    private var monoFormat: AVAudioFormat?
    private var currentLevel: Float = 0
    private var firstBufferHostTime: UInt64?
    var onFirstBufferHostTime: (@Sendable (UInt64) -> Void)?

    var audioLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return currentLevel
    }

    func configureOutput(url: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.fileURL = url
        self.audioFile = nil
        self.monoFormat = nil
        self.currentLevel = 0
        self.firstBufferHostTime = nil
    }

    func closeOutput() {
        lock.lock()
        defer { lock.unlock() }
        if #available(macOS 15.0, *) {
            audioFile?.close()
        }
        audioFile = nil
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio else {
            return
        }
        process(sampleBuffer)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        captureFirstBufferHostTimeIfNeeded(from: sampleBuffer)

        guard let pcmBuffer = createPCMBuffer(from: sampleBuffer) else {
            return
        }
        let monoSamples = downmixToMonoSamples(from: pcmBuffer)
        guard !monoSamples.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        if monoFormat == nil {
            monoFormat = AVAudioFormat(
                standardFormatWithSampleRate: pcmBuffer.format.sampleRate,
                channels: 1
            )
        }

        if audioFile == nil, let fileURL, let monoFormat {
            audioFile = try? AVAudioFile(
                forWriting: fileURL,
                settings: monoFormat.settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        }

        guard
            let monoFormat,
            let monoBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: AVAudioFrameCount(monoSamples.count)
            ),
            let channelData = monoBuffer.floatChannelData
        else {
            return
        }

        monoBuffer.frameLength = AVAudioFrameCount(monoSamples.count)
        monoSamples.withUnsafeBufferPointer { source in
            if let sourceBaseAddress = source.baseAddress {
                channelData[0].assign(from: sourceBaseAddress, count: monoSamples.count)
            }
        }

        try? audioFile?.write(from: monoBuffer)
        currentLevel = computeLevel(from: monoBuffer)
    }

    private func computeLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return 0
        }

        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for sampleIndex in 0..<frameCount {
                let sample = samples[sampleIndex]
                sumSquares += sample * sample
            }
        }

        let meanSquare = sumSquares / Float(frameCount * max(channelCount, 1))
        return min(max(sqrt(meanSquare), 0), 1)
    }

    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(numSamples)
        ) else {
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)

        var requiredSize = 0
        let queryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard queryStatus == noErr, requiredSize > 0 else {
            return nil
        }

        let audioBufferListRawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { audioBufferListRawPtr.deallocate() }

        let audioBufferListPtr = audioBufferListRawPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        let audioBufferList = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        if let channelData = pcmBuffer.floatChannelData {
            let channelCount = Int(format.channelCount)
            for channel in 0..<min(audioBufferList.count, channelCount) {
                let audioBuffer = audioBufferList[channel]
                if let sourceData = audioBuffer.mData?.assumingMemoryBound(to: Float.self) {
                    channelData[channel].initialize(from: sourceData, count: Int(pcmBuffer.frameLength))
                }
            }
        }

        return pcmBuffer
    }

    private func downmixToMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return []
        }

        var mono = Array(repeating: Float(0), count: frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }

    private func captureFirstBufferHostTimeIfNeeded(from sampleBuffer: CMSampleBuffer) {
        let callback: (@Sendable (UInt64) -> Void)?
        let hostTimeToEmit: UInt64?
        var didCaptureFirstHostTime = false

        lock.lock()
        if firstBufferHostTime == nil {
            let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTimeClock = CMClockGetHostTimeClock()
            let hostTime = CMSyncConvertTime(
                presentationTimestamp,
                from: hostTimeClock,
                to: hostTimeClock
            )

            if CMTIME_IS_VALID(hostTime), CMTIME_IS_NUMERIC(hostTime) {
                firstBufferHostTime = CMClockConvertHostTimeToSystemUnits(hostTime)
                didCaptureFirstHostTime = true
            }
        }
        callback = onFirstBufferHostTime
        hostTimeToEmit = didCaptureFirstHostTime ? firstBufferHostTime : nil
        lock.unlock()

        if let hostTimeToEmit {
            callback?(hostTimeToEmit)
        }
    }
}
