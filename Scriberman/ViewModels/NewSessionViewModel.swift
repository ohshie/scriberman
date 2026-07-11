import CoreAudio
import CoreGraphics
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class NewSessionViewModel {
    enum State {
        case idle
        case recording(duration: TimeInterval, level: Float)
    }

    private let workspaceService: WorkspaceServiceProtocol
    private let recordingService: RecordingServiceProtocol
    private let audioDeviceService: AudioDeviceServiceProtocol
    private let appAudioService: AppAudioServiceProtocol
    private let screenCaptureService: ScreenCaptureServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let liveTranscriptionService: LiveTranscriptionService
    private var recordingMonitorTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var activeRecordingSessionID: UUID?
    private let fileManager = FileManager.default
    var menuBarSettings: MenuBarSettings?
    var settingsViewModel: SettingsViewModel?

    var state: State = .idle
    // Separate wave inputs (design D4): the mic wave must not bounce when
    // only app audio is loud, so views get each source's level individually.
    private(set) var micAudioLevel: Float = 0
    private(set) var appAudioLevel: Float = 0
    var isIdle: Bool {
        if case .idle = state {
            return true
        }

        return false
    }
    var liveSegments: [TranscriptSegment] = []
    var errorMessage: String?
    var availableDevices: [AudioInputDevice] {
        audioDeviceService.availableDevices
    }
    var selectedDevice: AudioInputDevice? {
        get { audioDeviceService.selectedDevice }
        set {
            audioDeviceService.selectedDevice = newValue
            let desiredUID = newValue?.uid
            Task { [weak self] in
                await self?.retargetRecordingMicIfNeeded(desiredDeviceUID: desiredUID)
            }
        }
    }
    var runningApps: [CapturedApp] {
        appAudioService.runningApps
    }
    var availableDisplays: [CaptureDisplay] {
        screenCaptureService.availableDisplays
    }
    var selectedApp: CapturedApp? {
        get { appAudioService.selectedApp }
        set {
            appAudioService.selectedApp = newValue
        }
    }
    var selectedDisplayID: CGDirectDisplayID? {
        get { screenCaptureService.selectedDisplayID }
        set { screenCaptureService.selectedDisplayID = newValue }
    }
    var selectedDisplay: CaptureDisplay? {
        guard let selectedDisplayID else {
            return nil
        }
        return availableDisplays.first(where: { $0.displayID == selectedDisplayID })
    }
    private var screenRecordingStatus: PermissionStatus {
        permissionService.screenRecordingStatus
    }
    private var micStatus: PermissionStatus {
        permissionService.micStatus
    }
    var recordAppAudio: Bool = false {
        didSet {
            guard oldValue != recordAppAudio else {
                return
            }
            if recordAppAudio {
                guard screenRecordingPermissionGranted else {
                    recordAppAudio = false
                    requestScreenRecordingPermission()
                    return
                }
                restoreLastUsedApp()
            } else {
                selectedApp = nil
            }
        }
    }
    var recordScreen: Bool = false {
        didSet {
            guard oldValue != recordScreen else {
                return
            }
            if recordScreen {
                guard screenRecordingPermissionGranted else {
                    recordScreen = false
                    requestScreenRecordingPermission()
                    return
                }
                Task { [weak self] in
                    await self?.refreshAvailableDisplays()
                }
            }
        }
    }

    var appAudioToggleEnabled: Bool {
        true
    }

    var microphonePermissionGranted: Bool {
        micStatus == .granted
    }

    /// Reason shown on the microphone row's warning indicator; nil when access
    /// is granted (design D5).
    var micPermissionWarningText: String? {
        switch micStatus {
        case .granted:
            return nil
        case .notDetermined:
            return "Microphone access needed to record. Click to allow."
        case .denied:
            return "Microphone access is disabled. Click to open Privacy Settings."
        }
    }

    var micPermissionDenied: Bool {
        micStatus == .denied
    }

    /// Reason shown on the screen row's warning indicator; nil when screen
    /// recording permission is granted (design D5).
    var screenPermissionWarningText: String? {
        switch screenRecordingStatus {
        case .granted:
            return nil
        case .notDetermined:
            return "Screen Recording permission needed for app audio and screen capture. Click to allow."
        case .denied:
            return "Screen Recording is disabled. Click to open Privacy Settings."
        }
    }

    var screenPermissionDenied: Bool {
        screenRecordingStatus == .denied
    }

    var showAppPicker: Bool {
        recordAppAudio && screenRecordingStatus == .granted
    }

    var showDisplayPicker: Bool {
        recordScreen && screenRecordingStatus == .granted && availableDisplays.count > 1
    }

    var screenRecordingPermissionGranted: Bool {
        screenRecordingStatus == .granted
    }

    var canRecord: Bool {
        guard microphonePermissionGranted else {
            return false
        }
        if case .idle = state {
            if recordAppAudio && selectedApp == nil {
                return false
            }
            if recordScreen && effectiveCaptureDisplayID == nil {
                return false
            }
            return true
        }
        return false
    }

    init(
        workspaceService: WorkspaceServiceProtocol,
        recordingService: RecordingServiceProtocol,
        audioDeviceService: AudioDeviceServiceProtocol,
        appAudioService: AppAudioServiceProtocol,
        screenCaptureService: ScreenCaptureServiceProtocol,
        permissionService: PermissionServiceProtocol,
        speakerEmbeddingStore: SpeakerEmbeddingStore? = nil,
        userDefaults _: UserDefaults = .standard
    ) {
        self.liveTranscriptionService = LiveTranscriptionService(speakerEmbeddingStore: speakerEmbeddingStore)
        self.workspaceService = workspaceService
        self.recordingService = recordingService
        self.audioDeviceService = audioDeviceService
        self.appAudioService = appAudioService
        self.screenCaptureService = screenCaptureService
        self.permissionService = permissionService
        enforceAppAudioSelectionForCurrentPermissions()
    }

    func reset() {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        recordingStartedAt = nil
        activeRecordingSessionID = nil
        errorMessage = nil
        micAudioLevel = 0
        appAudioLevel = 0
        state = .idle
    }

    func refresh() async {
        _ = await workspaceService.currentWorkspace()
        await refreshAvailableDisplays()
    }

    func refreshApps() {
        appAudioService.refreshRunningApps()
    }

    func selectApp(_ app: CapturedApp?) {
        guard let app else {
            recordAppAudio = false
            return
        }

        guard screenRecordingPermissionGranted else {
            requestScreenRecordingPermission()
            return
        }

        selectedApp = app
        recordAppAudio = true
    }

    func refreshAudioDevicesOnAppear() {
        audioDeviceService.refreshDevices()
        Task {
            await recheckPermissions()
        }
        Task {
            await refreshAvailableDisplays()
        }
        // Pre-warm ASR + diarizer models when a workspace is available.
        Task {
            if let workspace = await workspaceService.currentWorkspace() {
                let pipelineConfig = settingsViewModel?.pipelineSettings ?? .defaults
                await liveTranscriptionService.prepare(workspace: workspace, config: pipelineConfig)
            }
        }
    }

    func refreshAudioDevicesOnPanelExpanded() {
        audioDeviceService.refreshDevices()
        Task {
            await recheckPermissions()
        }
        Task {
            await refreshAvailableDisplays()
        }
    }

    func requestMicrophonePermission() async {
        _ = await permissionService.requestMic()
    }

    func requestScreenRecordingPermission() {
        _ = permissionService.requestScreenRecording()
    }

    func recheckPermissions() async {
        permissionService.checkAll()
        _ = await permissionService.verifyMic()
        _ = await permissionService.verifyScreenRecording()
        enforceAppAudioSelectionForCurrentPermissions()
        await refreshAvailableDisplays()
    }

    func restoreLastUsedApp() {
        appAudioService.refreshRunningApps()
    }

    @discardableResult
    func startRecording(title: String, context: ModelContext) async -> RecordingSession? {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        errorMessage = nil

        do {
            let workspace = try await workspaceService.requireWritableWorkspace()
            appAudioService.refreshRunningApps()

            var selectedCapturedAppName: String?
            var selectedAppProcessID: pid_t?
            let captureDisplayID = effectiveCaptureDisplayID

            if recordAppAudio, let selectedApp {
                selectedCapturedAppName = selectedApp.name
                selectedAppProcessID = selectedApp.pid
            }

            let selectedMicDeviceID = selectedDevice?.id
            var startError: Error?
            var recordingSessionID: UUID?
            var fallbackMessage: String?

            do {
                recordingSessionID = try await startRecordingAttempt(
                    in: workspace,
                    micDeviceID: selectedMicDeviceID,
                    captureDisplayID: captureDisplayID,
                    capturedAppName: selectedCapturedAppName,
                    appProcessID: selectedAppProcessID,
                    title: title
                )
            } catch {
                startError = error
            }

            if startError != nil, selectedAppProcessID != nil {
                fallbackMessage = "App audio capture unavailable. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording."

                do {
                    recordingSessionID = try await startRecordingAttempt(
                        in: workspace,
                        micDeviceID: selectedMicDeviceID,
                        captureDisplayID: captureDisplayID,
                        capturedAppName: nil,
                        appProcessID: nil,
                        title: title
                    )
                    startError = nil
                } catch {
                    startError = error
                }
            }

            if startError != nil, selectedMicDeviceID != nil {
                do {
                    recordingSessionID = try await startRecordingAttempt(
                        in: workspace,
                        micDeviceID: nil,
                        captureDisplayID: captureDisplayID,
                        capturedAppName: nil,
                        appProcessID: nil,
                        title: title
                    )
                    startError = nil
                    if fallbackMessage == nil {
                        fallbackMessage = "Selected microphone unavailable. Falling back to system default microphone."
                    }
                } catch {
                    startError = error
                }
            }

            if let startError {
                throw startError
            }
            guard let recordingSessionID else {
                throw RecordingError.failedToStart("Recording session could not be created.")
            }

            if let selectedDevice {
                audioDeviceService.incrementUsage(for: selectedDevice.uid)
            }

            if let selectedApp {
                appAudioService.incrementUsage(for: selectedApp.bundleID)
            }

            menuBarSettings?.lastUsedMicUID = selectedDevice?.uid
            menuBarSettings?.lastUsedAppBundleID = selectedApp?.bundleID

            if let fallbackMessage {
                errorMessage = fallbackMessage
            }

            recordingStartedAt = .now
            activeRecordingSessionID = recordingSessionID
            state = .recording(duration: 0, level: 0)
            liveSegments = []

            let descriptor = FetchDescriptor<RecordingSession>()
            let session = try? context.fetch(descriptor).first(where: { $0.id == recordingSessionID })
            
            // Start Live Transcription
            do {
                let pipelineConfig = settingsViewModel?.pipelineSettings ?? .defaults
                try await liveTranscriptionService.start(workspace: workspace, config: pipelineConfig)
                startLiveTranscriptionPipeline(context: context)
            } catch LiveTranscriptionError.initializationFailed {
                errorMessage = "Live transcription unavailable: Required models are missing. Open Settings → Models to install ASR and Speaker Diarization models."
            } catch {
                errorMessage = "Live transcription unavailable: \(error.localizedDescription)"
            }
            
            startRecordingMonitor()
            return session
        } catch {
            errorMessage = error.localizedDescription
            state = .idle
            return nil
        }
    }

    @discardableResult
    func startRecording(
        title: String,
        micDeviceUID: String?,
        app: CapturedApp?,
        context: ModelContext
    ) async -> RecordingSession? {
        audioDeviceService.refreshDevices()
        appAudioService.refreshRunningApps()

        if let micDeviceUID {
            selectedDevice = availableDevices.first(where: { $0.uid == micDeviceUID })
        } else {
            selectedDevice = nil
        }

        selectedApp = app
        recordAppAudio = app != nil
        recordScreen = false

        return await startRecording(title: title, context: context)
    }

    func stopRecording(context: ModelContext) async -> RecordingSession? {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil

        let liveFinalSegments = await liveTranscriptionService.stop()
        let sessionID = await recordingService.stopRecording() ?? activeRecordingSessionID
        activeRecordingSessionID = nil
        
        var fetchedSession: RecordingSession?
        if let sessionID = sessionID {
            let descriptor = FetchDescriptor<RecordingSession>()
            if let sessions = try? context.fetch(descriptor) {
                for session in sessions where session.id == sessionID {
                    fetchedSession = session
                    break
                }
            }
        }
        
        guard let session = fetchedSession else {
            state = .idle
            return nil
        }

        backfillPersistedSegments(liveFinalSegments, to: session, context: context)
        saveLiveTranscript(to: session)
        try? context.save()
        
        state = .idle
        return session
    }

    private func saveLiveTranscript(to session: RecordingSession) {
        let finalSegments = session.transcriptSegments
            .filter(\.isFinal)
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.createdAt < $1.createdAt
                }
                return $0.startTime < $1.startTime
            }
            .map {
                TranscriptSegment(
                    id: $0.id,
                    speakerId: $0.speakerId,
                    text: $0.text,
                    startTime: $0.startTime,
                    endTime: $0.endTime,
                    audioSource: $0.audioSource,
                    isFinal: $0.isFinal
                )
            }
        
        if finalSegments.isEmpty {
            let transcript = Transcript(
                fullText: "",
                segments: [],
                speakers: []
            )
            session.transcript = transcript
            session.status = .done
            return
        }
        
        let speakerIds = Array(Set(finalSegments.map { $0.speakerId })).sorted()
        let speakers = speakerIds.enumerated().map { index, id in
            // "speaker_N" IDs come from the live diarizer; "unknown" is the fallback
            // when no diarizer match was found. Both map to a human-readable label.
            let isInternalId = id == "unknown" || id.hasPrefix("speaker_")
            return TranscriptSpeaker(
                id: id,
                label: isInternalId ? "Speaker \(index + 1)" : id,
                colorHex: "#007AFF"
            )
        }

        let transcript = Transcript(
            fullText: finalSegments.map { $0.text }.joined(separator: " "),
            segments: finalSegments,
            speakers: speakers
        )
        session.transcript = transcript
        session.status = .done
    }

    private func enforceAppAudioSelectionForCurrentPermissions() {
        guard screenRecordingStatus == .granted else {
            recordAppAudio = false
            recordScreen = false
            selectedApp = nil
            appAudioService.selectedApp = nil
            return
        }

        recordAppAudio = appAudioService.selectedApp != nil
    }

    private var effectiveCaptureDisplayID: CGDirectDisplayID? {
        guard recordScreen else {
            return nil
        }
        return selectedDisplayID
    }

    private func startRecordingMonitor() {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let isRecording = await recordingService.isRecording()
                guard isRecording else {
                    if let pendingError = await recordingService.consumePendingError() {
                        errorMessage = pendingError.localizedDescription
                        state = .idle
                    }
                    break
                }

                let levels = await recordingService.audioLevels()
                micAudioLevel = levels.mic
                appAudioLevel = levels.app
                let startedAt = recordingStartedAt ?? .now
                let duration = Date().timeIntervalSince(startedAt)
                state = .recording(duration: duration, level: max(levels.mic, levels.app))

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func startRecordingAttempt(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        captureDisplayID: CGDirectDisplayID?,
        capturedAppName: String?,
        appProcessID: pid_t?,
        title: String?
    ) async throws -> UUID {
        try await recordingService.startRecording(
            in: workspace,
            micDeviceID: micDeviceID,
            captureDisplayID: captureDisplayID,
            capturedAppName: capturedAppName,
            appProcessID: appProcessID,
            title: title
        )
    }

    private func refreshAvailableDisplays() async {
        guard screenRecordingPermissionGranted else {
            recordScreen = false
            return
        }
        await screenCaptureService.refreshAvailableDisplays()
    }

    private func retargetRecordingMicIfNeeded(desiredDeviceUID: String?) async {
        guard await recordingService.isRecording() else {
            return
        }
        await recordingService.retargetMic(desiredDeviceUID: desiredDeviceUID)
    }

    private func startLiveTranscriptionPipeline(context: ModelContext) {
        // Pipeline: buffers -> processor
        Task {
            for await (samples, source, sampleRate) in await recordingService.liveAudioStream() {
                await liveTranscriptionService.process(samples: samples, source: source, sampleRate: sampleRate)
            }
        }

        // Pipeline: results -> UI
        Task {
            for await segment in await liveTranscriptionService.transcriptStream {
                await MainActor.run {
                    updateLiveSegments(with: segment)
                    persistLiveTranscriptSegment(segment, context: context)
                }
            }
        }
    }

    private func persistLiveTranscriptSegment(_ segment: TranscriptSegment, context: ModelContext) {
        guard segment.isFinal, let sessionID = activeRecordingSessionID else {
            return
        }

        let descriptor = FetchDescriptor<RecordingSession>()
        guard let sessions = try? context.fetch(descriptor),
              let session = sessions.first(where: { $0.id == sessionID }),
              session.status == .recording
        else {
            return
        }

        if session.transcriptSegments.contains(where: { $0.id == segment.id }) {
            return
        }

        let persistedSegment = RecordingTranscriptSegment(segment: segment, session: session)
        context.insert(persistedSegment)
        try? context.save()
        appendSegmentToTranscriptMarkdown(persistedSegment, for: session)
    }

    private func backfillPersistedSegments(
        _ segments: [TranscriptSegment],
        to session: RecordingSession,
        context: ModelContext
    ) {
        let existingIDs = Set(session.transcriptSegments.map(\.id))
        let missingSegments = segments.filter { $0.isFinal && !existingIDs.contains($0.id) }

        for segment in missingSegments {
            let persistedSegment = RecordingTranscriptSegment(
                segment: segment,
                createdAt: Date(),
                session: session
            )
            context.insert(persistedSegment)
            appendSegmentToTranscriptMarkdown(persistedSegment, for: session)
        }
    }

    private func appendSegmentToTranscriptMarkdown(_ segment: RecordingTranscriptSegment, for session: RecordingSession) {
        appendTranscriptSegmentToMarkdown(segment, for: session, fileManager: fileManager)
    }

    private func updateLiveSegments(with segment: TranscriptSegment) {
        // 1. Retroactive speaker correction: a segment with this id already exists in
        //    liveSegments and the diarizer has now assigned it a real speaker.
        if let existingIndex = liveSegments.firstIndex(where: { $0.id == segment.id }) {
            liveSegments[existingIndex] = segment
            return
        }

        // 2. Rolling partial update: replace the last non-final segment from the same source.
        if let lastIndex = liveSegments.indices.last, !liveSegments[lastIndex].isFinal {
            if liveSegments[lastIndex].audioSource == segment.audioSource {
                liveSegments[lastIndex] = segment
                return
            }
        }

        // 3. New segment — append and cap the buffer.
        liveSegments.append(segment)
        if liveSegments.count > 100 {
            liveSegments.removeFirst(liveSegments.count - 100)
        }
    }
}
