import Combine
import CoreAudio
import Foundation
import SwiftData

@MainActor
final class NewSessionViewModel: ObservableObject {
    enum State {
        case idle
        case recording(duration: TimeInterval, level: Float)
        case stopped(session: RecordingSession)
    }

    private let workspaceService: WorkspaceServiceProtocol
    private let recordingService: RecordingServiceProtocol
    private let audioDeviceService: AudioDeviceServiceProtocol
    private let appAudioService: AppAudioServiceProtocol
    private let permissionService: PermissionServiceProtocol
    private let userDefaults: UserDefaults
    private let lastUsedAppNameKey = "lastUsedAppName"
    private var recordingMonitorTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingServiceSelection = false
    private var isApplyingAppSelection = false

    @Published var state: State = .idle
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
            lastUsedAppName = selectedApp?.name
            guard !isApplyingAppSelection else {
                return
            }
            appAudioService.selectedApp = selectedApp
        }
    }
    @Published private var screenRecordingStatus: PermissionStatus
    @Published private var micStatus: PermissionStatus
    @Published var recordAppAudio: Bool = false {
        didSet {
            guard oldValue != recordAppAudio else {
                return
            }
            if recordAppAudio {
                restoreLastUsedApp()
            } else {
                appAudioService.selectedApp = nil
            }
        }
    }

    var appAudioToggleEnabled: Bool {
        screenRecordingStatus == .granted
    }

    var microphonePermissionGranted: Bool {
        micStatus == .granted
    }

    var shouldShowMicrophonePermissionPrompt: Bool {
        if case .idle = state {
            return !microphonePermissionGranted
        }
        return false
    }

    var microphonePermissionPromptText: String {
        switch micStatus {
        case .notDetermined:
            return "Allow microphone access to start recording."
        case .denied:
            return "Microphone access is disabled. Allow access in System Settings to start recording."
        case .granted:
            return ""
        }
    }

    var showAppPicker: Bool {
        recordAppAudio && screenRecordingStatus == .granted
    }

    var canRecord: Bool {
        guard microphonePermissionGranted else {
            return false
        }
        if case .idle = state {
            return !recordAppAudio || selectedApp != nil
        }
        return false
    }

    private var lastUsedAppName: String? {
        get { userDefaults.string(forKey: lastUsedAppNameKey) }
        set {
            if let newValue {
                userDefaults.set(newValue, forKey: lastUsedAppNameKey)
            } else {
                userDefaults.removeObject(forKey: lastUsedAppNameKey)
            }
        }
    }

    init(
        workspaceService: WorkspaceServiceProtocol,
        recordingService: RecordingServiceProtocol,
        audioDeviceService: AudioDeviceServiceProtocol,
        appAudioService: AppAudioServiceProtocol,
        permissionService: PermissionServiceProtocol,
        userDefaults: UserDefaults = .standard
    ) {
        self.workspaceService = workspaceService
        self.recordingService = recordingService
        self.audioDeviceService = audioDeviceService
        self.appAudioService = appAudioService
        self.permissionService = permissionService
        self.userDefaults = userDefaults
        self.availableDevices = audioDeviceService.availableDevices
        self.selectedDevice = audioDeviceService.selectedDevice
        self.runningApps = appAudioService.runningApps
        self.selectedApp = appAudioService.selectedApp
        self.screenRecordingStatus = permissionService.screenRecordingStatus
        self.micStatus = permissionService.micStatus

        handleScreenRecordingStatusChange(permissionService.screenRecordingStatus)

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
                self?.handleScreenRecordingStatusChange(status)
            }
            .store(in: &cancellables)

        permissionService.micStatusPublisher
            .sink { [weak self] status in
                self?.micStatus = status
            }
            .store(in: &cancellables)
    }

    func reset() {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        recordingStartedAt = nil
        errorMessage = nil
        state = .idle
    }

    func refresh() async {
        _ = await workspaceService.currentWorkspace()
    }

    func refreshApps() {
        appAudioService.refreshRunningApps()
    }

    func requestMicrophonePermission() async {
        _ = await permissionService.requestMic()
    }

    func restoreLastUsedApp() {
        let lastUsedAppName = lastUsedAppName
        appAudioService.refreshRunningApps()
        guard let lastUsedAppName else {
            selectedApp = nil
            return
        }

        selectedApp = runningApps.first(where: { $0.name == lastUsedAppName })
    }

    func startRecording(title: String, context _: ModelContext) async {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil
        errorMessage = nil

        do {
            let workspace = try await workspaceService.requireWritableWorkspace()
            appAudioService.refreshRunningApps()

            var selectedCapturedAppName: String?
            var selectedAppProcessID: pid_t?

            if recordAppAudio, let selectedApp {
                selectedCapturedAppName = selectedApp.name
                selectedAppProcessID = selectedApp.pid
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

            if let selectedDevice {
                audioDeviceService.incrementUsage(for: selectedDevice.uid)
            }

            if let fallbackMessage {
                errorMessage = fallbackMessage
            }

            recordingStartedAt = .now
            state = .recording(duration: 0, level: 0)
            startRecordingMonitor()
        } catch {
            errorMessage = error.localizedDescription
            state = .idle
        }
    }

    func stopRecording(context _: ModelContext) async {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = nil

        let session = await recordingService.stopRecording()
        guard let session else {
            state = .idle
            return
        }

        state = .stopped(session: session)
    }

    private func handleScreenRecordingStatusChange(_ status: PermissionStatus) {
        screenRecordingStatus = status

        guard status == .granted else {
            recordAppAudio = false
            selectedApp = nil
            appAudioService.selectedApp = nil
            lastUsedAppName = nil
            return
        }
    }

    private func applySelectedDeviceFromService(_ device: AudioInputDevice?) {
        isApplyingServiceSelection = true
        selectedDevice = device
        isApplyingServiceSelection = false
    }

    private func applySelectedAppFromService(_ app: CapturedApp?) {
        if app == nil, !recordAppAudio, selectedApp != nil {
            return
        }
        isApplyingAppSelection = true
        selectedApp = app
        isApplyingAppSelection = false
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

                let level = await recordingService.audioLevel()
                let startedAt = recordingStartedAt ?? .now
                let duration = Date().timeIntervalSince(startedAt)
                state = .recording(duration: duration, level: level)

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
}
