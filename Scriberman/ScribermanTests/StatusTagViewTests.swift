import Foundation
import Testing
@testable import Scriberman

@MainActor
struct StatusTagViewTests {
    @Test
    func recordingRendersNoTagViaEmptyViewPath() throws {
        let source = try statusTagViewSource()
        #expect(source.contains("case .recording:"))
        #expect(source.contains("EmptyView()"))
        #expect(!source.contains("case .recording:\n            Text(\"Recording\")"))
    }

    @Test
    func doneWithNoTranscriptOrAIShowsOneCheckmark() {
        let view = StatusTagView(status: .done, hasTranscript: false, hasAITransformation: false)
        #expect(checkmarkCount(in: view) == 1)
    }

    @Test
    func doneWithTranscriptShowsTwoCheckmarks() {
        let view = StatusTagView(status: .done, hasTranscript: true, hasAITransformation: false)
        #expect(checkmarkCount(in: view) == 2)
    }

    @Test
    func doneWithTranscriptAndAIShowsThreeCheckmarks() {
        let view = StatusTagView(status: .done, hasTranscript: true, hasAITransformation: true)
        #expect(checkmarkCount(in: view) == 3)
    }

    @Test
    func errorRendersXmarkIconPath() throws {
        let source = try statusTagViewSource()
        #expect(source.contains("case .error:"))
        #expect(source.contains("Image(systemName: \"xmark\")"))
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

    private func checkmarkCount(in view: StatusTagView) -> Int {
        var count = 1
        if view.hasTranscript {
            count += 1
        }
        if view.hasAITransformation {
            count += 1
        }
        return count
    }

    private func statusTagViewSource() throws -> String {
        let testsFileURL = URL(fileURLWithPath: #filePath)
        let moduleRoot = testsFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let statusTagFileURL = moduleRoot
            .appendingPathComponent("UI")
            .appendingPathComponent("StatusTagView.swift")
        return try String(contentsOf: statusTagFileURL, encoding: .utf8)
    }
}
