import FluidAudio
import Foundation
import Testing
@testable import Scriberman

final class ModelInstallServiceTests {
    @Test
    func testValidateInstalledRepoASRParakeetV3UsesV3RequiredModels() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.asrParakeetV3.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.ASR.requiredModelsV3(precision: .int8), in: repoURL)
        try createFile(ModelNames.ASR.vocabulary(for: .parakeetV3), in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .asrParakeetV3, at: repoURL)
        #expect(isValid)
    }

    @Test
    func testValidateInstalledRepoASRParakeetV3RejectsLegacyJointModelSet() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.asrParakeetV3.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.ASR.requiredModels, in: repoURL)
        try createFile(ModelNames.ASR.vocabulary(for: .parakeetV3), in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .asrParakeetV3, at: repoURL)
        #expect(!isValid)
    }

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
    func testValidateInstalledRepoLSEENDAcceptsInstalledModelFile() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.lseendDiarization.repoFolderName, isDirectory: true)
        try createRequiredFiles([ModelPathResolver.lseendModelRelativePath], in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .lseendDiarization, at: repoURL)
        #expect(isValid)
    }

    @Test
    func testValidateInstalledRepoLSEENDRejectsEmptyFolder() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.lseendDiarization.repoFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        let isValid = try await service.validateInstalledRepoForTesting(for: .lseendDiarization, at: repoURL)
        #expect(!isValid)
    }

    @Test

    func testWarmUpModelsCompletesWithoutThrowWhenModelDirectoriesExist() async throws {
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
            },
            warmUpLSEEND: {
                await probe.markLSEENDAttempted()
            }
        )

        let didRunASR = await probe.didRunASR()
        let didRunDiarizer = await probe.didRunDiarizer()
        let didAttemptVAD = await probe.didAttemptVAD()
        let didAttemptLSEEND = await probe.didAttemptLSEEND()

        #expect(didRunASR)
        #expect(didRunDiarizer)
        #expect(didAttemptVAD)
        #expect(didAttemptLSEEND)
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
            },
            warmUpLSEEND: {
                await probe.markLSEENDAttempted()
            }
        )

        let didRunASR = await probe.didRunASR()
        let didRunDiarizer = await probe.didRunDiarizer()
        let didAttemptVAD = await probe.didAttemptVAD()
        let didAttemptLSEEND = await probe.didAttemptLSEEND()

        #expect(didRunASR)
        #expect(didRunDiarizer)
        #expect(didAttemptVAD)
        #expect(didAttemptLSEEND)
    }

    @Test

    func testWarmUpModelsLSEENDFailureIsNonFatal() async {
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
            },
            warmUpLSEEND: {
                await probe.markLSEENDAttempted()
                throw TestWarmUpError.lseendFailed
            }
        )

        let didRunASR = await probe.didRunASR()
        let didRunDiarizer = await probe.didRunDiarizer()
        let didAttemptVAD = await probe.didAttemptVAD()
        let didAttemptLSEEND = await probe.didAttemptLSEEND()

        #expect(didRunASR)
        #expect(didRunDiarizer)
        #expect(didAttemptVAD)
        #expect(didAttemptLSEEND)
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
            try createFile(relativePath, in: repoURL)
        }
    }

    private func createFile(_ relativePath: String, in repoURL: URL) throws {
        let fileURL = repoURL.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    }
}

private struct InMemoryBookmarkStore: BookmarkStore {
    func loadWorkspaceBookmark() -> Data? { nil }
    func saveWorkspaceBookmark(_ data: Data) {}
}

private enum TestWarmUpError: Error {
    case vadFailed
    case lseendFailed
}

private actor WarmUpProbe {
    private var asr = false
    private var diarizer = false
    private var vad = false
    private var lseend = false

    func markASR() { asr = true }
    func markDiarizer() { diarizer = true }
    func markVADAttempted() { vad = true }
    func markLSEENDAttempted() { lseend = true }
    func didRunASR() -> Bool { asr }
    func didRunDiarizer() -> Bool { diarizer }
    func didAttemptVAD() -> Bool { vad }
    func didAttemptLSEEND() -> Bool { lseend }
}
