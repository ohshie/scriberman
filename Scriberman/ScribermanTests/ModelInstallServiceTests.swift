import FluidAudio
import Foundation
import XCTest
@testable import Scriberman

final class ModelInstallServiceTests: XCTestCase {
    func testValidateInstalledRepoOfflineDiarizationReturnsFalseWhenOnlyStreamingFilesPresent() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.Diarizer.requiredModels, in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .offlineDiarization, at: repoURL)
        XCTAssertFalse(isValid)
    }

    func testValidateInstalledRepoOfflineDiarizationReturnsTrueWhenStreamingAndOfflineFilesPresent() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.Diarizer.requiredModels, in: repoURL)
        try createRequiredFiles(ModelNames.OfflineDiarizer.requiredModels, in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .offlineDiarization, at: repoURL)
        XCTAssertTrue(isValid)
    }

    func testValidateInstalledRepoOfflineDiarizationReturnsFalseWhenOnlyOfflineFilesPresent() async throws {
        let service = makeService()
        let tempRoot = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let repoURL = tempRoot.appendingPathComponent(ModelGroup.offlineDiarization.repoFolderName, isDirectory: true)
        try createRequiredFiles(ModelNames.OfflineDiarizer.requiredModels, in: repoURL)

        let isValid = try await service.validateInstalledRepoForTesting(for: .offlineDiarization, at: repoURL)
        XCTAssertFalse(isValid)
    }

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
