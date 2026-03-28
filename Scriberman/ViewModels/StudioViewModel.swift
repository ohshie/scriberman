import Combine
import CoreAudio
import Foundation

@MainActor
final class StudioViewModel: ObservableObject {
    enum RecordingState {
        case idle
        case recording(duration: TimeInterval, level: Float)
        case stopped(session: RecordingSession, ctaSecondsRemaining: Int)
    }

    private let workspaceService: WorkspaceServiceProtocol
    private let recordingService: RecordingServiceProtocol
    private let audioDeviceService: AudioDeviceServiceProtocol
    private let appAudioService: AppAudioServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private var recordingMonitorTask: Task<Void, Never>?
    private var ctaCountdownTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var stoppedSessionForCTA: RecordingSession?
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingServiceSelection = false
    private var isApplyingAppSelection = false

    @Published var recordingState: RecordingState = .idle
    @Published var errorMessage: String?
    @Published var availableDevices: [AudioInputDevice]
    @Published var selectedDevice: AudioInputDevice? {
        didSet {
            guard !isApplyingServiceSelection else {
                return
            }
            audioDeviceService.selectedDevice = selectedDevice
        }
    }
    @Published var runningApps: [CapturedApp]
    @Published var selectedApp: CapturedApp? {
        didSet {
            guard !isApplyingAppSelection else {
                return
            }
            appAudioService.selectedApp = selectedApp
        }
    }
    @Published var appPickerEnabled: Bool
    var onSessionStopped: ((RecordingSession) -> Void)?

    init(
        workspaceService: WorkspaceServiceProtocol,
        recordingService: RecordingServiceProtocol,
        audioDeviceService: AudioDeviceServiceProtocol,
        appAudioService: AppAudioServiceProtocol,
        permissionService: PermissionServiceProtocol
    ) {
        self.workspaceService = workspaceService
        self.recordingService = recordingService
        self.audioDeviceService = audioDeviceService
        self.appAudioService = appAudioService
        self.permissionService = permissionService
        self.availableDevices = audioDeviceService.availableDevices
        self.selectedDevice = audioDeviceService.selectedDevice
        self.runningApps = appAudioService.runningApps
        self.selectedApp = appAudioService.selectedApp
        self.appPickerEnabled = permissionService.screenRecordingStatus == .granted

        audioDeviceService.availableDevicesPublisher
            .sink { [weak self] devices in
                self?.availableDevices = devices
            }
            .store(in: &cancellables)

        audioDeviceService.selectedDevicePublisher
            .sink { [weak self] device in
                self?.applySelectedDeviceFromService(device)
            }
            .store(in: &cancellables)

        appAudioService.runningAppsPublisher
            .sink { [weak self] apps in
                self?.runningApps = apps
            }
            .store(in: &cancellables)

        appAudioService.selectedAppPublisher
            .sink { [weak self] app in
                self?.applySelectedAppFromService(app)
            }
            .store(in: &cancellables)

        permissionService.screenRecordingStatusPublisher
            .sink { [weak self] status in
                self?.appPickerEnabled = status == .granted
            }
            .store(in: &cancellables)
    }

    func refresh() async {
        _ = await workspaceService.currentWorkspace()
    }

    private func applySelectedDeviceFromService(_ device: AudioInputDevice?) {
        isApplyingServiceSelection = true
        selectedDevice = device
        isApplyingServiceSelection = false
    }

    private func applySelectedAppFromService(_ app: CapturedApp?) {
        isApplyingAppSelection = true
        selectedApp = app
        isApplyingAppSelection = false
    }

    func refreshApps() {
        appAudioService.refreshRunningApps()
    }

    func startRecording() async {
        ctaCountdownTask?.cancel()
        ctaCountdownTask = nil
        errorMessage = nil

        do {
            let workspace = try await workspaceService.requireWritableWorkspace()
            appAudioService.refreshRunningApps()

            var selectedCapturedAppName: String?
            var selectedAppProcessID: pid_t?

            if let selectedApp {
                if permissionService.screenRecordingStatus == .granted {
                    selectedCapturedAppName = selectedApp.name
                    selectedAppProcessID = selectedApp.pid
                } else {
                    errorMessage = "App audio capture permission denied. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording."
                }
            }

            let selectedMicDeviceID = selectedDevice?.id

            var startError: Error?
            var fallbackMessage: String?

            do {
                    try await startRecordingAttempt(
                        in: workspace,
                        micDeviceID: selectedMicDeviceID,
                        capturedAppName: selectedCapturedAppName,
                        appProcessID: selectedAppProcessID
                    )
            } catch {
                startError = error
            }

            if startError != nil, selectedAppProcessID != nil {
                fallbackMessage = "App audio capture unavailable. Enable Scriberman in System Settings > Privacy & Security > Screen & System Audio Recording, then relaunch app. Falling back to microphone-only recording."

                do {
                    try await startRecordingAttempt(
                        in: workspace,
                        micDeviceID: selectedMicDeviceID,
                        capturedAppName: nil,
                        appProcessID: nil
                    )
                    startError = nil
                } catch {
                    startError = error
                }
            }

            if startError != nil, selectedMicDeviceID != nil {
                do {
                    try await startRecordingAttempt(
                        in: workspace,
                        micDeviceID: nil,
                        capturedAppName: nil,
                        appProcessID: nil
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

            if let fallbackMessage {
                errorMessage = fallbackMessage
            }

            recordingStartedAt = Date()
            recordingState = .recording(duration: 0, level: 0)
            startRecordingMonitor()
        } catch {
            errorMessage = error.localizedDescription
            recordingState = .idle
        }
    }

    func stopRecording() async {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil

        let session = await recordingService.stopRecording()
        guard let session else {
            recordingState = .idle
            return
        }

        stoppedSessionForCTA = session
        recordingState = .stopped(session: session, ctaSecondsRemaining: 15)
        onSessionStopped?(session)
        startCtaCountdown()
    }

    func consumeSessionForTranscribeCTA() -> RecordingSession? {
        ctaCountdownTask?.cancel()
        ctaCountdownTask = nil
        let session = stoppedSessionForCTA
        stoppedSessionForCTA = nil
        recordingState = .idle
        return session
    }

    func clearStoppedCTAIfNeeded() {
        guard case .stopped = recordingState else {
            return
        }
        ctaCountdownTask?.cancel()
        ctaCountdownTask = nil
        stoppedSessionForCTA = nil
        recordingState = .idle
    }

    private func startRecordingMonitor() {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let isRecording = await recordingService.isRecording()
                guard isRecording else {
                    if let pendingError = await recordingService.consumePendingError() {
                        errorMessage = pendingError.localizedDescription
                        recordingState = .idle
                    }
                    break
                }

                let level = await recordingService.audioLevel()
                let startedAt = recordingStartedAt ?? Date()
                let duration = Date().timeIntervalSince(startedAt)
                recordingState = .recording(duration: duration, level: level)

                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func startRecordingAttempt(
        in workspace: Workspace,
        micDeviceID: AudioDeviceID?,
        capturedAppName: String?,
        appProcessID: pid_t?
    ) async throws {
        try await recordingService.startRecording(
            in: workspace,
            micDeviceID: micDeviceID,
            capturedAppName: capturedAppName,
            appProcessID: appProcessID
        )
    }

    private func startCtaCountdown() {
        ctaCountdownTask?.cancel()
        ctaCountdownTask = Task { [weak self] in
            var remaining = 15
            while let self, !Task.isCancelled, remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
                guard case let .stopped(session, _) = recordingState else {
                    return
                }
                if remaining <= 0 {
                    stoppedSessionForCTA = nil
                    recordingState = .idle
                } else {
                    recordingState = .stopped(session: session, ctaSecondsRemaining: remaining)
                }
            }
        }
    }
}
