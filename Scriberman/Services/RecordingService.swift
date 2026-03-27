import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
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
    private let aggregateDeviceBuilder: AggregateDeviceBuilding
    private let notificationCenter: NotificationCenter
    private let fileManager = FileManager.default

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingStartedAt: Date?
    private var recordingURL: URL?
    private var hasScopedRecordingAccess = false
    private var recordingWorkspaceRootURL: URL?
    private var activeTapID: AudioObjectID?
    private var activeAggregateDeviceID: AudioDeviceID?
    private var activeCapturedAppName: String?
    private var pendingError: RecordingError?
    private var engineConfigurationObserver: NSObjectProtocol?

    private var isRecordingValue = false
    private var audioLevelValue: Float = 0

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        aggregateDeviceBuilder: AggregateDeviceBuilding = AggregateDeviceBuilder(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.aggregateDeviceBuilder = aggregateDeviceBuilder
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
        audioLevelValue
    }

    func startRecording(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID? = nil,
        tapID: AudioObjectID? = nil,
        aggregateDeviceID: AudioDeviceID? = nil,
        capturedAppName: String? = nil
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

            let recordingIdentifier = UUID().uuidString
            let fileURL = workspace.recordingsURL.appendingPathComponent("\(recordingIdentifier).wav")
            let audioEngine = AVAudioEngine()
            let inputNode = audioEngine.inputNode

            if let aggregateDeviceID {
                guard let inputAudioUnit = inputNode.audioUnit else {
                    throw RecordingError.failedToStart("Audio input unit is unavailable.")
                }

                var targetDeviceID = aggregateDeviceID
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

                guard status == noErr else {
                    throw RecordingError.failedToStart("Unable to configure aggregate capture device (OSStatus \(status)).")
                }
            } else if let micDeviceID {
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

            let audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
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
            self.recordingStartedAt = Date()
            self.recordingURL = fileURL
            self.isRecordingValue = true
            self.audioLevelValue = 0
            self.pendingError = nil
            self.activeTapID = tapID
            self.activeAggregateDeviceID = aggregateDeviceID
            self.activeCapturedAppName = capturedAppName
        } catch {
            cleanupAggregateCaptureIfNeeded()
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
        cleanupAggregateCaptureIfNeeded()

        let startedAt = recordingStartedAt ?? Date()
        let createdAt = Date()
        let duration = max(0, createdAt.timeIntervalSince(startedAt))

        guard let recordingURL else {
            cleanupRecordingState()
            return nil
        }

        let session = RecordingSession(
            createdAt: createdAt,
            duration: duration,
            audioURL: recordingURL.path,
            title: makeSessionTitle(createdAt: createdAt),
            capturedAppName: activeCapturedAppName,
            status: .recorded
        )

        do {
            let context = ModelContext(modelContainer)
            context.insert(session)
            try context.save()
            cleanupRecordingState()
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
        recordingStartedAt = nil
        recordingURL = nil
        activeTapID = nil
        activeAggregateDeviceID = nil
        activeCapturedAppName = nil
    }

    private func releaseRecordingScopeIfNeeded() {
        guard hasScopedRecordingAccess, let recordingWorkspaceRootURL else {
            return
        }

        recordingWorkspaceRootURL.stopAccessingSecurityScopedResource()
        hasScopedRecordingAccess = false
        self.recordingWorkspaceRootURL = nil
    }

    private func cleanupAggregateCaptureIfNeeded() {
        guard let activeTapID, let activeAggregateDeviceID else {
            activeTapID = nil
            activeAggregateDeviceID = nil
            return
        }

        aggregateDeviceBuilder.teardown(
            tapID: activeTapID,
            aggregateDeviceID: activeAggregateDeviceID
        )
        self.activeTapID = nil
        self.activeAggregateDeviceID = nil
    }

    private func handleAudioEngineConfigurationChange() async {
        guard isRecordingValue else {
            return
        }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        cleanupAggregateCaptureIfNeeded()
        cleanupRecordingState()
        audioLevelValue = 0
        isRecordingValue = false
        pendingError = .captureInterrupted
        releaseRecordingScopeIfNeeded()
    }
}
