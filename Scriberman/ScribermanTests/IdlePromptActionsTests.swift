import CoreGraphics
import Foundation
import Testing
@testable import Scriberman

private final class StubIdlePromptAppAudioService: AppAudioServiceProtocol {
    var runningApps: [CapturedApp] = []
    var selectedApp: CapturedApp?
    func incrementUsage(for _: String) {}
    func refreshRunningApps() {}
}

@MainActor
private final class StubIdlePromptScreenCaptureService: ScreenCaptureServiceProtocol {
    var availableDisplays: [CaptureDisplay] = []
    var selectedDisplayID: CGDirectDisplayID?
    func refreshAvailableDisplays() async {}
}

/// Contract between the floating prompt's buttons and the view model: both actions dismiss
/// the panel, and `Stop & Save` (plus auto-stop, which routes through the same call) goes
/// through the injected stop handler — i.e. the normal `stopRecording(context:)` path, so the
/// session finalizes, mixes down, and queues transcription exactly like a manual stop.
@MainActor
struct IdlePromptActionsTests {
    private func makeViewModel() -> NewSessionViewModel {
        NewSessionViewModel(
            workspaceService: MockWorkspaceService(),
            recordingService: MockRecordingService(),
            audioDeviceService: MockAudioDeviceService(),
            appAudioService: StubIdlePromptAppAudioService(),
            screenCaptureService: StubIdlePromptScreenCaptureService(),
            permissionService: MockPermissionService()
        )
    }

    @Test("Stop & Save routes through the injected stop handler")
    func stopRoutesThroughNormalPath() async {
        let viewModel = makeViewModel()
        var stopCalls = 0
        viewModel.onIdlePromptStopRequested = { stopCalls += 1 }
        viewModel.isIdlePromptVisible = true

        await viewModel.stopFromIdlePrompt()

        #expect(stopCalls == 1)
        #expect(!viewModel.isIdlePromptVisible)
    }

    @Test("Stop & Save hides the panel")
    func stopHidesPanel() async {
        let viewModel = makeViewModel()
        var presentationChanges: [Bool] = []
        viewModel.onIdlePromptPresentationChanged = { presentationChanges.append($0) }
        viewModel.onIdlePromptStopRequested = {}
        viewModel.isIdlePromptVisible = true

        await viewModel.stopFromIdlePrompt()

        #expect(presentationChanges == [false])
    }

    @Test("Snooze hides the panel without stopping the recording")
    func snoozeDoesNotStop() {
        let viewModel = makeViewModel()
        var stopCalls = 0
        var presentationChanges: [Bool] = []
        viewModel.onIdlePromptStopRequested = { stopCalls += 1 }
        viewModel.onIdlePromptPresentationChanged = { presentationChanges.append($0) }
        viewModel.isIdlePromptVisible = true

        viewModel.snoozeIdlePrompt(for: 5 * 60)

        #expect(stopCalls == 0)
        #expect(!viewModel.isIdlePromptVisible)
        #expect(presentationChanges == [false])
    }

    @Test("Settings come from the injected provider so Settings changes take effect live")
    func settingsComeFromProvider() {
        let viewModel = makeViewModel()
        #expect(viewModel.idlePromptSettings == .default)

        var custom = IdlePromptSettings.default
        custom.idleThreshold = 20 * 60
        custom.autoStopEnabled = true
        viewModel.idlePromptPreferencesProvider = { custom }

        #expect(viewModel.idlePromptSettings.idleThreshold == 20 * 60)
        #expect(viewModel.idlePromptSettings.autoStopEnabled)
    }
}
