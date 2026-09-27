import FluidAudio
import Foundation
import SwiftData
import Testing
@testable import Scriberman

final class ModelInstallServiceTests {
    @Test
    func testValidateInstalledRepoASRParakeetUltraUsesV3FileSet() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.asrParakeetUltra.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.ASR.requiredModelsV3(), in: repoURL)
        try createFile(ModelNames.ASR.vocabulary(for: .parakeetV3), in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .asrParakeetUltra, at: repoURL)
        #expect(isValid)
    }

    @Test
    func testValidateInstalledRepoASRParakeetUltraRejectsLegacyJointModelSet() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.asrParakeetUltra.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.ASR.requiredModels, in: repoURL)
        try createFile(ModelNames.ASR.vocabulary(for: .parakeetV3), in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .asrParakeetUltra, at: repoURL)
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
    func testValidateInstalledRepoNemotron3AcceptsPresetBundleAssetsAndWeightsMarker() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.nemotron3Diarization.repoFolderName, isDirectory: true)
        try createNemotron3Install(in: repoURL, weightsVersion: ModelNames.Nemotron3.weightsVersion)

        let isValid = try await service.validateInstalledRepoForTesting(for: .nemotron3Diarization, at: repoURL)
        #expect(isValid)
    }

    @Test
    func testValidateInstalledRepoNemotron3RejectsStaleWeightsMarker() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.nemotron3Diarization.repoFolderName, isDirectory: true)
        try createNemotron3Install(in: repoURL, weightsVersion: "an-earlier-release")

        let isValid = try await service.validateInstalledRepoForTesting(for: .nemotron3Diarization, at: repoURL)
        #expect(!isValid)
    }

    @Test
    func testValidateInstalledRepoNemotron3RejectsMissingWeightsMarker() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.nemotron3Diarization.repoFolderName, isDirectory: true)
        try createNemotron3Install(in: repoURL, weightsVersion: nil)

        let isValid = try await service.validateInstalledRepoForTesting(for: .nemotron3Diarization, at: repoURL)
        #expect(!isValid)
    }

    @Test
    func testValidateInstalledRepoNemotron3RejectsLegacyLSEENDFolder() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try createFile("ls-eend/dih3/100ms/model.mlmodelc/coremldata.bin", in: tempRoot)

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.nemotron3Diarization.repoFolderName, isDirectory: true)
        let isValid = try await service.validateInstalledRepoForTesting(for: .nemotron3Diarization, at: repoURL)
        #expect(!isValid)
    }

    @Test
    func testNemotron3FolderMatchesFluidAudioRepoFolder() {
        #expect(ModelGroup.nemotron3Diarization.repoFolderName == Repo.nemotron3Diarization.folderName)
        #expect(ModelPathResolver.nemotron3LoadConfig.modelFileName == ModelPathResolver.nemotron3BundleRelativePath)
    }

    @Test
    func testReplacedLSEENDFolderRemovedAfterNemotron3Install() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let legacyURL = tempRoot.appendingPathComponent("ls-eend", isDirectory: true)
        try createFile("dih3/100ms/model.mlmodelc/coremldata.bin", in: legacyURL)

        await service.removeReplacedInstallForTesting(of: .nemotron3Diarization, in: tempRoot)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
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
            warmUpTurnDiarizer: {
                await probe.markTurnDiarizerAttempted()
            }
        )

        let didRunASR = await probe.didRunASR()
        let didRunDiarizer = await probe.didRunDiarizer()
        let didAttemptVAD = await probe.didAttemptVAD()
        let didAttemptTurnDiarizer = await probe.didAttemptTurnDiarizer()

        #expect(didRunASR)
        #expect(didRunDiarizer)
        #expect(didAttemptVAD)
        #expect(didAttemptTurnDiarizer)
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
            warmUpTurnDiarizer: {
                await probe.markTurnDiarizerAttempted()
            }
        )

        let didRunASR = await probe.didRunASR()
        let didRunDiarizer = await probe.didRunDiarizer()
        let didAttemptVAD = await probe.didAttemptVAD()
        let didAttemptTurnDiarizer = await probe.didAttemptTurnDiarizer()

        #expect(didRunASR)
        #expect(didRunDiarizer)
        #expect(didAttemptVAD)
        #expect(didAttemptTurnDiarizer)
    }

    @Test

    func testWarmUpModelsTurnDiarizerFailureIsNonFatal() async {
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
            warmUpTurnDiarizer: {
                await probe.markTurnDiarizerAttempted()
                throw TestWarmUpError.turnDiarizerFailed
            }
        )

        let didRunASR = await probe.didRunASR()
        let didRunDiarizer = await probe.didRunDiarizer()
        let didAttemptVAD = await probe.didAttemptVAD()
        let didAttemptTurnDiarizer = await probe.didAttemptTurnDiarizer()

        #expect(didRunASR)
        #expect(didRunDiarizer)
        #expect(didAttemptVAD)
        #expect(didAttemptTurnDiarizer)
    }

    @Test
    func testUltraGroupIsNotSatisfiedByLegacyV3Folder() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let legacyURL = tempRoot.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        try createRequiredFiles(ModelNames.ASR.requiredModelsV3(), in: legacyURL)
        try createFile(ModelNames.ASR.vocabulary(for: .parakeetV3), in: legacyURL)

        let ultraURL = tempRoot.appendingPathComponent(ModelGroup.asrParakeetUltra.repoFolderName, isDirectory: true)
        let isValid = try await service.validateInstalledRepoForTesting(for: .asrParakeetUltra, at: ultraURL)
        #expect(!isValid)
    }

    @Test
    func testUltraFolderMatchesFluidAudioRepoFolder() {
        // AsrModels.load(from:version:) resolves the repo by this name next to the given directory.
        #expect(ModelGroup.asrParakeetUltra.repoFolderName == Repo.parakeetUltra.folderName)
        #expect(ModelPathResolver.asrModelVersion == .ultra)
    }

    @Test
    func testReplacedV3FolderRemovedAfterUltraInstall() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let legacyURL = tempRoot.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        try createRequiredFiles(ModelNames.ASR.requiredModelsV3(), in: legacyURL)

        await service.removeReplacedInstallForTesting(of: .asrParakeetUltra, in: tempRoot)

        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test
    func testReplacedFolderRemovalLeavesOtherGroupsAlone() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let legacyURL = tempRoot.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        try createRequiredFiles(ModelNames.ASR.requiredModelsV3(), in: legacyURL)

        await service.removeReplacedInstallForTesting(of: .vadSilero, in: tempRoot)

        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test
    func testReplacedFolderRemovalIsNonFatalWhenFolderMissing() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        await service.removeReplacedInstallForTesting(of: .asrParakeetUltra, in: tempRoot)
    }

    @Test
    func testStampRevisionMarkerWritesPinnedRevisionWhenMissing() throws {
        let repoURL = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: repoURL) }

        let didStamp = try ModelInstallService.stampRevisionMarkerIfMissing(at: repoURL, revision: Repo.diarizer.revision)

        #expect(didStamp)
        let markerURL = repoURL.appendingPathComponent(ModelInstallService.revisionMarkerFileName)
        let stored = try String(contentsOf: markerURL, encoding: .utf8)
        #expect(stored == Repo.diarizer.revision + "\n")
    }

    @Test
    func testStampRevisionMarkerLeavesExistingMarkerUntouched() throws {
        let repoURL = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        let markerURL = repoURL.appendingPathComponent(ModelInstallService.revisionMarkerFileName)
        try Data("older-revision\n".utf8).write(to: markerURL)

        let didStamp = try ModelInstallService.stampRevisionMarkerIfMissing(at: repoURL, revision: Repo.diarizer.revision)

        #expect(!didStamp)
        #expect(try String(contentsOf: markerURL, encoding: .utf8) == "older-revision\n")
    }

    @Test
    func testDiarizerRevisionIsPinned() {
        // The stamp only matters while FluidAudio pins this repo; on "main" no marker is needed.
        #expect(Repo.diarizer.revision != "main")
    }

    @Test
    func testFailedReplacementPreservesPreviousFiles() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(rootURL: root)
        let installed = workspace.modelsURL.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName)
        try createRequiredFiles(ModelNames.Diarizer.requiredModels, in: installed)
        try createRequiredFiles(ModelNames.OfflineDiarizer.requiredModels, in: installed)
        try Data("previous revision\n".utf8).write(to: installed.appendingPathComponent(ModelInstallService.revisionMarkerFileName))
        try Data([0, 1, 2, 255]).write(to: installed.appendingPathComponent("previous.bin"))
        let before = try snapshot(installed)
        for failsDownload in [false, true] {
            let service = try await makeInstallService(root: root) { group, staging, _ in
                #expect(staging == workspace.modelsURL.appendingPathComponent(".staging", isDirectory: true))
                let target = staging.appendingPathComponent(group.repoFolderName)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try Data("incomplete".utf8).write(to: target.appendingPathComponent("partial"))
                if failsDownload { throw URLError(.notConnectedToInternet) }
            }
            do {
                _ = try await service.installModelGroup(.offlineDiarization)
                Issue.record("Expected failed replacement")
            } catch {}
            #expect(try snapshot(installed) == before)
            #expect(!FileManager.default.fileExists(atPath: workspace.modelsURL.appendingPathComponent(".staging/speaker-diarization").path))
        }
    }

    @Test
    func testValidGroupsSkipDownloader() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(rootURL: root)
        for group in ModelGroup.allCases {
            try Self.createInstall(group, root: workspace.modelsURL)
        }
        let service = try await makeInstallService(root: root) { _, _, _ in
            Issue.record("Valid install must not download")
            throw URLError(.notConnectedToInternet)
        }
        let before = try snapshot(workspace.modelsURL)
        for group in ModelGroup.allCases {
            _ = try await service.installModelGroup(group)
            #expect(await service.state(for: group) == .ready)
        }
        #expect(try snapshot(workspace.modelsURL) == before)
    }

    @Test
    func testStaleRevisionIsReplacedOnlyAfterValidation() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(rootURL: root)
        try Self.createInstall(.offlineDiarization, root: workspace.modelsURL)
        let installed = workspace.modelsURL.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName)
        let marker = installed.appendingPathComponent(ModelInstallService.revisionMarkerFileName)
        try Data("stale\n".utf8).write(to: marker)
        try Data("old".utf8).write(to: installed.appendingPathComponent("obsolete"))
        let service = try await makeInstallService(root: root) { group, staging, _ in
            #expect(try String(contentsOf: marker, encoding: .utf8) == "stale\n")
            try Self.createInstall(group, root: staging)
        }
        #expect(await service.state(for: .offlineDiarization) == .missing)
        _ = try await service.installModelGroup(.offlineDiarization)
        #expect(await service.state(for: .offlineDiarization) == .ready)
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent("obsolete").path))
    }

    @Test @MainActor
    func testDownloadAllRetryDownloadsOnlyRemainingGroups() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceService = WorkspaceService(
            bookmarkStore: InMemoryBookmarkStore(), startAccess: { _ in true }, stopAccess: { _ in },
            createBookmark: { _ in Data() }
        )
        let workspace = try await workspaceService.setWorkspace(url: root)
        let probe = DownloadProbe()
        let service = ModelInstallService(workspaceService: workspaceService) { group, staging, _ in
            try await probe.download(group, root: staging)
        }
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        let viewModel = SettingsViewModel(
            workspaceService: workspaceService, modelInstallService: service,
            speakerEmbeddingStore: SpeakerEmbeddingStore(modelContainer: container)
        )
        viewModel.canDownloadModels = true
        await viewModel.downloadAllTapped()
        #expect(await probe.calls == [.asrParakeetUltra, .vadSilero, .offlineDiarization])
        let asrBefore = try snapshot(workspace.modelsURL.appendingPathComponent(ModelGroup.asrParakeetUltra.repoFolderName))
        // Fail the fourth group too, so this filesystem test never loads fake CoreML models.
        await probe.failOnFourth()
        await viewModel.downloadAllTapped()
        #expect(await probe.calls == [.asrParakeetUltra, .vadSilero, .offlineDiarization, .offlineDiarization, .nemotron3Diarization])
        #expect(try snapshot(workspace.modelsURL.appendingPathComponent(ModelGroup.asrParakeetUltra.repoFolderName)) == asrBefore)
    }

    @Test
    func testClearStagingPreservesInstalledModels() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(rootURL: root)
        try Self.createInstall(.vadSilero, root: workspace.modelsURL)
        let installed = workspace.modelsURL.appendingPathComponent(ModelGroup.vadSilero.repoFolderName)
        let before = try snapshot(installed)
        try createFile(".staging/abandoned/partial", in: workspace.modelsURL)
        let service = try await makeInstallService(root: root) { _, _, _ in }
        try await service.clearStaging()
        try await service.clearStaging()
        #expect(!FileManager.default.fileExists(atPath: workspace.modelsURL.appendingPathComponent(".staging").path))
        #expect(try snapshot(installed) == before)
    }

    @Test
    func testWarmUpFailureSetsErrorAndSuccessfulRetryClearsIt() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.createInstall(.vadSilero, root: Workspace(rootURL: root).modelsURL)
        let service = try await makeInstallService(root: root) { _, _, _ in }
        let failures = await service.warmUpModelsForTesting(
            warmUpASR: {}, warmUpDiarizer: {},
            warmUpVAD: { throw TestWarmUpError.vadFailed }, warmUpTurnDiarizer: {}
        )
        #expect(failures[.vadSilero] == TestWarmUpError.vadFailed.localizedDescription)
        #expect(await service.state(for: .vadSilero) == .error)
        let retried = await service.warmUpModelsForTesting(
            warmUpASR: {}, warmUpDiarizer: {}, warmUpVAD: {}, warmUpTurnDiarizer: {}
        )
        #expect(retried.isEmpty)
        #expect(await service.state(for: .vadSilero) == .ready)
    }

    private func makeInstallService(root: URL, downloader: @escaping ModelInstallService.Downloader) async throws -> ModelInstallService {
        let workspaceService = WorkspaceService(
            bookmarkStore: InMemoryBookmarkStore(), startAccess: { _ in true }, stopAccess: { _ in },
            createBookmark: { _ in Data() }
        )
        _ = try await workspaceService.setWorkspace(url: root)
        return ModelInstallService(workspaceService: workspaceService, downloader: downloader)
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return files
    }

    fileprivate static func createInstall(_ group: ModelGroup, root: URL) throws {
        let repo = root.appendingPathComponent(group.repoFolderName)
        let files: Set<String>
        switch group {
        case .asrParakeetUltra:
            files = ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabulary(for: .parakeetUltra)])
        case .vadSilero:
            files = ModelNames.VAD.requiredModels
        case .offlineDiarization:
            files = ModelNames.Diarizer.requiredModels.union(ModelNames.OfflineDiarizer.requiredModels)
        case .nemotron3Diarization:
            files = ModelPathResolver.nemotron3RequiredAssets.union([ModelPathResolver.nemotron3BundleRelativePath + "/coremldata.bin"])
        }
        for name in files {
            let url = repo.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("model bytes".utf8).write(to: url)
        }
        if group == .offlineDiarization {
            _ = try ModelInstallService.stampRevisionMarkerIfMissing(at: repo, revision: Repo.diarizer.revision)
        }
        if group == .nemotron3Diarization {
            try Data((ModelNames.Nemotron3.weightsVersion + "\n").utf8).write(to: repo.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile))
        }
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

    private func createNemotron3Install(in repoURL: URL, weightsVersion: String?) throws {
        try createFile(ModelPathResolver.nemotron3BundleRelativePath + "/coremldata.bin", in: repoURL)
        try createRequiredFiles(ModelPathResolver.nemotron3RequiredAssets, in: repoURL)
        if let weightsVersion {
            let markerURL = repoURL.appendingPathComponent(ModelNames.Nemotron3.weightsVersionFile)
            try Data((weightsVersion + "\n").utf8).write(to: markerURL)
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
    case turnDiarizerFailed
}

private actor WarmUpProbe {
    private var asr = false
    private var diarizer = false
    private var vad = false
    private var turnDiarizer = false

    func markASR() { asr = true }
    func markDiarizer() { diarizer = true }
    func markVADAttempted() { vad = true }
    func markTurnDiarizerAttempted() { turnDiarizer = true }
    func didRunASR() -> Bool { asr }
    func didRunDiarizer() -> Bool { diarizer }
    func didAttemptVAD() -> Bool { vad }
    func didAttemptTurnDiarizer() -> Bool { turnDiarizer }
}

private actor DownloadProbe {
    var calls: [ModelGroup] = []
    private var failure: ModelGroup = .offlineDiarization
    func failOnFourth() { failure = .nemotron3Diarization }
    func download(_ group: ModelGroup, root: URL) throws {
        calls.append(group)
        if group == failure { throw URLError(.notConnectedToInternet) }
        try ModelInstallServiceTests.createInstall(group, root: root)
    }
}
