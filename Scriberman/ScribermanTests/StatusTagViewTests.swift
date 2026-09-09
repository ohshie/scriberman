import FluidAudio
import Foundation
import Testing
import os
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

    /// `.done` is the resting state and most of the list, so it carries no marker at all. A
    /// checkmark that is always present when the status is `.done` only repeats the status.
    @Test
    func doneRendersNothing() throws {
        let source = try statusTagViewSource()
        let doneRange = try #require(source.range(of: "case .done:"))
        let rest = source[doneRange.upperBound...]
        let nextCase = rest.range(of: "case .")?.lowerBound ?? rest.endIndex
        let body = rest[..<nextCase]
        #expect(body.contains("EmptyView()"))
        // Matches the rendered symbol, not prose — the explanatory comment names it too.
        #expect(!body.contains("Image(systemName: \"checkmark\")"))
    }

    /// Transcript and AI-transformation presence are no longer shown in the list, so the view no
    /// longer takes them. Leaving them as unused parameters would invite a caller to believe they
    /// still mean something.
    @Test
    func doneCarriesNoTranscriptOrTransformationSignal() throws {
        let source = try statusTagViewSource()
        #expect(!source.contains("hasTranscript"))
        #expect(!source.contains("hasAITransformation"))
        #expect(!source.contains("doneCheckmarkCount"))
    }

    @Test
    func errorRendersXmarkIconPath() throws {
        let source = try statusTagViewSource()
        #expect(source.contains("case .error:"))
        #expect(source.contains("Image(systemName: \"xmark\")"))
    }

    @Test
    func downloadProgressHandlerNormalizesRepoDownloadsByPhaseWeight() {
        // Repo downloads (ASR/VAD/diarizer) emit fractions in [0, 0.5]: the
        // upper half of ModelHub's range belongs to a compile phase that
        // never runs for plain downloads. A finished download must report 1.0.
        let recorded = OSAllocatedUnfairLock(initialState: [Double]())
        let handler = ModelInstallService.makeDownloadProgressHandler(
            downloadProgress: { value in recorded.withLock { $0.append(value) } },
            downloadPhaseWeight: 0.5
        )

        handler?(DownloadProgress(fractionCompleted: 0.0, phase: .listing))
        handler?(DownloadProgress(fractionCompleted: 0.25, phase: .downloading(completedFiles: 1, totalFiles: 4)))
        handler?(DownloadProgress(fractionCompleted: 0.5, phase: .downloading(completedFiles: 4, totalFiles: 4)))

        #expect(recorded.withLock { $0 } == [0.0, 0.5, 1.0])
    }

    @Test
    func downloadProgressHandlerForwardsSubdirectoryDownloadsUnscaled() {
        // Subdirectory downloads (LS-EEND) span the full [0, 1] range.
        let recorded = OSAllocatedUnfairLock(initialState: [Double]())
        let handler = ModelInstallService.makeDownloadProgressHandler(
            downloadProgress: { value in recorded.withLock { $0.append(value) } },
            downloadPhaseWeight: 1.0
        )

        handler?(DownloadProgress(fractionCompleted: 0.25, phase: .downloading(completedFiles: 1, totalFiles: 4)))
        handler?(DownloadProgress(fractionCompleted: 1.0, phase: .downloading(completedFiles: 4, totalFiles: 4)))

        #expect(recorded.withLock { $0 } == [0.25, 1.0])
    }

    @Test
    func downloadProgressHandlerNeverRegressesBelowRunningMax() {
        let recorded = OSAllocatedUnfairLock(initialState: [Double]())
        let handler = ModelInstallService.makeDownloadProgressHandler(
            downloadProgress: { value in recorded.withLock { $0.append(value) } },
            downloadPhaseWeight: 1.0
        )

        handler?(DownloadProgress(fractionCompleted: 0.6, phase: .downloading(completedFiles: 2, totalFiles: 4)))
        handler?(DownloadProgress(fractionCompleted: 0.4, phase: .downloading(completedFiles: 0, totalFiles: 2)))
        handler?(DownloadProgress(fractionCompleted: 0.8, phase: .downloading(completedFiles: 1, totalFiles: 2)))

        #expect(recorded.withLock { $0 } == [0.6, 0.6, 0.8])
    }

    @Test
    func downloadProgressHandlerClampsOutOfRangeFractions() {
        let recorded = OSAllocatedUnfairLock(initialState: [Double]())
        let handler = ModelInstallService.makeDownloadProgressHandler(
            downloadProgress: { value in recorded.withLock { $0.append(value) } },
            downloadPhaseWeight: 0.5
        )

        handler?(DownloadProgress(fractionCompleted: -0.5, phase: .listing))
        handler?(DownloadProgress(fractionCompleted: 1.5, phase: .compiling(modelName: "Encoder.mlmodelc")))

        #expect(recorded.withLock { $0 } == [0.0, 1.0])
    }

    @Test
    func downloadPhaseWeightMatchesModelHubAPIPerGroup() {
        #expect(ModelInstallService.downloadPhaseWeight(for: .asrParakeetV3) == 0.5)
        #expect(ModelInstallService.downloadPhaseWeight(for: .vadSilero) == 0.5)
        #expect(ModelInstallService.downloadPhaseWeight(for: .offlineDiarization) == 0.5)
        #expect(ModelInstallService.downloadPhaseWeight(for: .lseendDiarization) == 1.0)
    }

    @Test
    func makeDownloadProgressHandlerReturnsNilWhenCallbackIsNil() {
        let handler = ModelInstallService.makeDownloadProgressHandler(
            downloadProgress: nil,
            downloadPhaseWeight: 0.5
        )
        #expect(handler == nil)
    }

    @Test
    func modelGroupsListContainsExactlyFourRequiredRows() {
        #expect(ModelGroup.allCases.count == 4)
        #expect(ModelGroup.allCases == [.asrParakeetV3, .vadSilero, .offlineDiarization, .lseendDiarization])
    }

    @Test
    func modelGroupTitlesMatchSettingsRows() {
        #expect(ModelGroup.asrParakeetV3.title == "ASR (Parakeet v3)")
        #expect(ModelGroup.vadSilero.title == "VAD (Silero CoreML)")
        #expect(ModelGroup.offlineDiarization.title == "Diarization (Global Offline)")
        #expect(ModelGroup.lseendDiarization.title == "Turn Diarization (LS-EEND)")
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
