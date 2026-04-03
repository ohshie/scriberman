import Testing
@testable import Scriberman

@MainActor
struct StatusTagViewTests {
    @Test
    func doneMapsToGreenTint() {
        let style = StatusTagView.style(for: .done)
        #expect(style.label == "Done")
        #expect(style.tint == .green)
    }

    @Test
    func pendingMapsToOrangeTint() {
        #expect(StatusTagView.style(for: .recorded).tint == .orange)
        #expect(StatusTagView.style(for: .converting).tint == .orange)
        #expect(StatusTagView.style(for: .transcribing).tint == .orange)
        #expect(StatusTagView.style(for: .retranscribing).tint == .orange)
    }

    @Test
    func failedMapsToRedTint() {
        let style = StatusTagView.style(for: .error("boom"))
        #expect(style.label == "Failed")
        #expect(style.tint == .red)
    }

    @Test
    func normalizedDownloadProgressScalesAndCapsAtOne() {
        #expect(abs(ModelInstallService.normalizedDownloadProgress(from: 0.0) - 0.0) < 0.0001)
        #expect(abs(ModelInstallService.normalizedDownloadProgress(from: 0.25) - 0.5) < 0.0001)
        #expect(abs(ModelInstallService.normalizedDownloadProgress(from: 0.5) - 1.0) < 0.0001)
        #expect(abs(ModelInstallService.normalizedDownloadProgress(from: 0.9) - 1.0) < 0.0001)
    }

    @Test
    func makeDownloadProgressHandlerReturnsNilWhenCallbackIsNil() {
        let handler = ModelInstallService.makeDownloadProgressHandler(downloadProgress: nil)
        #expect(handler == nil)
    }

    @Test
    func modelGroupsListContainsExactlyThreeRequiredRows() {
        #expect(ModelGroup.allCases.count == 3)
        #expect(ModelGroup.allCases == [.asrParakeetV3, .vadSilero, .offlineDiarization])
    }

    @Test
    func modelGroupTitlesMatchSettingsRows() {
        #expect(ModelGroup.asrParakeetV3.title == "ASR (Parakeet v3)")
        #expect(ModelGroup.vadSilero.title == "VAD (Silero CoreML)")
        #expect(ModelGroup.offlineDiarization.title == "Diarization (Global Offline)")
    }
}
