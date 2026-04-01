import XCTest
@testable import Scriberman

final class StatusTagViewTests: XCTestCase {
    func testDoneMapsToGreenTint() {
        let style = StatusTagView.style(for: .done)
        XCTAssertEqual(style.label, "Done")
        XCTAssertEqual(style.tint, .green)
    }

    func testPendingMapsToOrangeTint() {
        XCTAssertEqual(StatusTagView.style(for: .recorded).tint, .orange)
        XCTAssertEqual(StatusTagView.style(for: .converting).tint, .orange)
        XCTAssertEqual(StatusTagView.style(for: .transcribing).tint, .orange)
        XCTAssertEqual(StatusTagView.style(for: .retranscribing).tint, .orange)
    }

    func testFailedMapsToRedTint() {
        let style = StatusTagView.style(for: .error("boom"))
        XCTAssertEqual(style.label, "Failed")
        XCTAssertEqual(style.tint, .red)
    }

    func testNormalizedDownloadProgressScalesAndCapsAtOne() {
        XCTAssertEqual(ModelInstallService.normalizedDownloadProgress(from: 0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(ModelInstallService.normalizedDownloadProgress(from: 0.25), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ModelInstallService.normalizedDownloadProgress(from: 0.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ModelInstallService.normalizedDownloadProgress(from: 0.9), 1.0, accuracy: 0.0001)
    }

    func testMakeDownloadProgressHandlerReturnsNilWhenCallbackIsNil() {
        let handler = ModelInstallService.makeDownloadProgressHandler(downloadProgress: nil)
        XCTAssertNil(handler)
    }

    func testDownloadingWithProgressUsesDeterminateIndicatorAndHidesAction() {
        let presentation = ModelsSettingsView.makeRowPresentation(
            state: .downloading,
            progress: 0.42,
            canDownloadModels: true
        )

        XCTAssertEqual(presentation.indicator, .determinateProgress(value: 0.42, phaseLabel: "Downloading…"))
        XCTAssertNil(presentation.actionTitle)
        XCTAssertFalse(presentation.isActionEnabled)
    }

    func testInstallingUsesIndeterminateIndicatorAndHidesAction() {
        let presentation = ModelsSettingsView.makeRowPresentation(
            state: .installing,
            progress: nil,
            canDownloadModels: true
        )

        XCTAssertEqual(presentation.indicator, .indeterminateProgress(phaseLabel: "Installing…"))
        XCTAssertNil(presentation.actionTitle)
        XCTAssertFalse(presentation.isActionEnabled)
    }

    func testErrorStateShowsRetryAction() {
        let presentation = ModelsSettingsView.makeRowPresentation(
            state: .error,
            progress: nil,
            canDownloadModels: true
        )

        XCTAssertEqual(presentation.indicator, .capsule(label: ModelGroupReadinessState.error.rawValue))
        XCTAssertEqual(presentation.actionTitle, "Retry")
        XCTAssertTrue(presentation.isActionEnabled)
    }

    func testModelGroupsListContainsExactlyThreeRequiredRows() {
        XCTAssertEqual(ModelGroup.allCases.count, 3)
        XCTAssertEqual(ModelGroup.allCases, [.asrParakeetV3, .vadSilero, .offlineDiarization])
    }

    func testModelGroupTitlesMatchSettingsRows() {
        XCTAssertEqual(ModelGroup.asrParakeetV3.title, "ASR (Parakeet v3)")
        XCTAssertEqual(ModelGroup.vadSilero.title, "VAD (Silero CoreML)")
        XCTAssertEqual(ModelGroup.offlineDiarization.title, "Diarization (Global Offline)")
    }
}
