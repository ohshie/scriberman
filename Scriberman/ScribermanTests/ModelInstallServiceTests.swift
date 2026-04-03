import FluidAudio
import Foundation
import Testing
@testable import Scriberman

final class ModelInstallServiceTests {
    @Test
    func testValidateInstalledRepoOfflineDiarizationReturnsFalseWhenOnlyStreamingFilesPresent() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.Diarizer.requiredModels, in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .offlineDiarization, at: repoURL)
        #expect(!(isValid))
    }

    @Test

    func testValidateInstalledRepoOfflineDiarizationReturnsTrueWhenStreamingAndOfflineFilesPresent() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.Diarizer.requiredModels, in: repoURL)
        try createRequiredFiles(ModelNames.OfflineDiarizer.requiredModels, in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .offlineDiarization, at: repoURL)
        #expect(isValid)
    }

    @Test

    func testValidateInstalledRepoOfflineDiarizationReturnsFalseWhenOnlyOfflineFilesPresent() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.OfflineDiarizer.requiredModels, in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .offlineDiarization, at: repoURL)
        #expect(!(isValid))
    }

    @Test

    func testWarmUpModelsCompletesWithoutThrowWhenModelDirectoriesExist() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let workspace = Workspace(rootURL: tempRoot)
        try FileManager.default.createDirectory(
            at: workspace.modelsURL.appendingPathComponent(ModelGroup.asrParakeetV3.repoFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: workspace.modelsURL.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )

        await service.warmUpModels(workspace: workspace)
    }

    @Test

    func testWarmUpModelsVADFailureIsNonFatalWhenASRAndDiarizerWarmUpSucceed() async {
        let service = makeService()
        let probe = WarmUpProbe()

        await service.warmUpModelsForTesting(
            warmUpASR: {
                await probe.markASR()
            },
            warmUpDiarizer: {
                await probe.markDiarizer()
            },
            warmUpVAD: {
                await probe.markVADAttempted()
                throw TestWarmUpError.vadFailed
            }
        )

        let didRunASR = await probe.didRunASR()
        let didRunDiarizer = await probe.didRunDiarizer()
        let didAttemptVAD = await probe.didAttemptVAD()

        #expect(didRunASR)
        #expect(didRunDiarizer)
        #expect(didAttemptVAD)
    }

    private func makeService() -> ModelInstallService {
        ModelInstallService(workspaceService: WorkspaceService(bookmarkStore: InMemoryBookmarkStore()))
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createRequiredFiles(_ required: Set<String>, in repoURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: repoURL, withIntermediateDirectories: true)

        for relativePath in required {
            let fileURL = repoURL.appendingPathComponent(relativePath, isDirectory: false)
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: fileURL.path, contents: Data())
        }
    }
}

private struct InMemoryBookmarkStore: BookmarkStore {
    func loadWorkspaceBookmark() -> Data? { nil }
    func saveWorkspaceBookmark(_ data: Data) {}
}

private enum TestWarmUpError: Error {
    case vadFailed
}

private actor WarmUpProbe {
    private var asr = false
    private var diarizer = false
    private var vad = false

    func markASR() { asr = true }
    func markDiarizer() { diarizer = true }
    func markVADAttempted() { vad = true }
    func didRunASR() -> Bool { asr }
    func didRunDiarizer() -> Bool { diarizer }
    func didAttemptVAD() -> Bool { vad }
}
