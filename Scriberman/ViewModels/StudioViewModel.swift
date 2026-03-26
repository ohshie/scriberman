import Foundation

@MainActor
final class StudioViewModel: ObservableObject {
    enum RecordingState {
        case idle
        case recording(duration: TimeInterval, level: Float)
        case stopped(session: RecordingSession, ctaSecondsRemaining: Int)
    }

    private let workspaceService: WorkspaceService
    private let recordingService: RecordingService
    private var recordingMonitorTask: Task<Void, Never>?
    private var ctaCountdownTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var stoppedSessionForCTA: RecordingSession?

    @Published var recordingState: RecordingState = .idle
    @Published var errorMessage: String?
    var onSessionStopped: ((RecordingSession) -> Void)?

    init(workspaceService: WorkspaceService, recordingService: RecordingService) {
        self.workspaceService = workspaceService
        self.recordingService = recordingService
    }

    func refresh() async {
        _ = await workspaceService.currentWorkspace()
    }

    func startRecording() async {
        ctaCountdownTask?.cancel()
        ctaCountdownTask = nil
        errorMessage = nil

        do {
            let workspace = try await workspaceService.requireWritableWorkspace()
            try await recordingService.startRecording(in: workspace)
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

    private func startRecordingMonitor() {
        recordingMonitorTask?.cancel()
        recordingMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let isRecording = await recordingService.isRecording()
                guard isRecording else {
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
