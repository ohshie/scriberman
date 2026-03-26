import FluidAudio
import Foundation

enum ModelInstallError: LocalizedError {
    case workspaceNotWritable
    case stagedRepositoryNotFound(ModelGroup, searched: [String])
    case validationFailed(ModelGroup, path: URL)

    var errorDescription: String? {
        switch self {
        case .workspaceNotWritable:
            return "Workspace is not writable. Please re-authorize your workspace folder."
        case .stagedRepositoryNotFound(let group, let searched):
            let searchSummary = searched.joined(separator: "\n")
            return "Could not locate staged model repo for \(group.title).\nSearched:\n\(searchSummary)"
        case .validationFailed(let group, let path):
            return "Installed files for \(group.title) are incomplete at \(path.path)."
        }
    }
}

actor ModelInstallService {
    private let workspaceService: WorkspaceService
    private let fileManager = FileManager.default

    init(workspaceService: WorkspaceService) {
        self.workspaceService = workspaceService
    }

    func ensureWorkspaceWriteAccess() async throws -> Workspace {
        try await workspaceService.requireWritableWorkspace()
    }

    func canInstallModels() async -> Bool {
        do {
            _ = try await ensureWorkspaceWriteAccess()
            return true
        } catch {
            return false
        }
    }

    func state(for group: ModelGroup) async -> ModelGroupReadinessState {
        guard let workspace = await workspaceService.currentWorkspace() else {
            return .missing
        }

        let repoURL = workspace.modelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)
        do {
            return try validateInstalledRepo(for: group, at: repoURL) ? .ready : .missing
        } catch {
            return .error
        }
    }

    @discardableResult
    func installModelGroup(
        _ group: ModelGroup,
        progress: (@Sendable (ModelGroupReadinessState) -> Void)? = nil
    ) async throws -> URL {
        let workspace: Workspace
        do {
            workspace = try await ensureWorkspaceWriteAccess()
        } catch {
            throw ModelInstallError.workspaceNotWritable
        }

        progress?(.downloading)
        try await triggerFluidAudioDownload(for: group)

        let stagingLookup = locateStagedRepository(for: group)
        guard let stagedRepoURL = stagingLookup.repoURL else {
            throw ModelInstallError.stagedRepositoryNotFound(group, searched: stagingLookup.searchedPaths)
        }

        progress?(.installing)
        let installedURL = try installAtomically(
            group: group,
            stagedRepoURL: stagedRepoURL,
            workspaceModelsURL: workspace.modelsURL
        )

        let isValid = try validateInstalledRepo(for: group, at: installedURL)
        guard isValid else {
            throw ModelInstallError.validationFailed(group, path: installedURL)
        }

        cleanupStagingCache(for: group)
        return installedURL
    }

    // MARK: - Download (FluidAudio helpers)

    private func triggerFluidAudioDownload(for group: ModelGroup) async throws {
        switch group {
        case .asrParakeetV3:
            _ = try await AsrModels.download(version: .v3)

        case .vadSilero:
            _ = try await VadManager()

        case .diarization:
            _ = try await DiarizerModels.downloadIfNeeded()
        }
    }

    // MARK: - Staging lookup (task 5.2 spike)

    private struct StagingLookupResult {
        let repoURL: URL?
        let searchedPaths: [String]
    }

    private func locateStagedRepository(for group: ModelGroup) -> StagingLookupResult {
        var searched: [String] = []

        for root in stagingSearchRoots() {
            let candidate = root.appendingPathComponent(group.repoFolderName, isDirectory: true)
            searched.append(candidate.path)

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return StagingLookupResult(repoURL: candidate, searchedPaths: searched)
            }
        }

        return StagingLookupResult(repoURL: nil, searchedPaths: searched)
    }

    private func stagingSearchRoots() -> [URL] {
        var roots: [URL] = []

        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(appSupport.appendingPathComponent("FluidAudio", isDirectory: true).appendingPathComponent("Models", isDirectory: true))
        }

        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches.appendingPathComponent("FluidAudio", isDirectory: true).appendingPathComponent("Models", isDirectory: true))
        }

        return roots
    }

    // MARK: - Atomic install

    private func installAtomically(
        group: ModelGroup,
        stagedRepoURL: URL,
        workspaceModelsURL: URL
    ) throws -> URL {
        try fileManager.createDirectory(at: workspaceModelsURL, withIntermediateDirectories: true)

        let finalURL = workspaceModelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)
        let partialURL = workspaceModelsURL.appendingPathComponent("\(group.repoFolderName).partial", isDirectory: true)
        let backupURL = workspaceModelsURL.appendingPathComponent("\(group.repoFolderName).backup", isDirectory: true)

        try removeIfExists(partialURL)
        try removeIfExists(backupURL)

        do {
            try fileManager.copyItem(at: stagedRepoURL, to: partialURL)

            guard try validateInstalledRepo(for: group, at: partialURL) else {
                throw ModelInstallError.validationFailed(group, path: partialURL)
            }

            if fileManager.fileExists(atPath: finalURL.path) {
                try fileManager.moveItem(at: finalURL, to: backupURL)
            }

            try fileManager.moveItem(at: partialURL, to: finalURL)
            try removeIfExists(backupURL)
        } catch {
            try? removeIfExists(partialURL)

            if fileManager.fileExists(atPath: backupURL.path), !fileManager.fileExists(atPath: finalURL.path) {
                try? fileManager.moveItem(at: backupURL, to: finalURL)
            }

            throw error
        }

        return finalURL
    }

    private func removeIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    // MARK: - Validation

    private func validateInstalledRepo(for group: ModelGroup, at repoURL: URL) throws -> Bool {
        switch group {
        case .asrParakeetV3:
            return AsrModels.modelsExist(at: repoURL, version: .v3)

        case .vadSilero:
            return requiredFilesExist(in: repoURL, required: ModelNames.VAD.requiredModels)

        case .diarization:
            return requiredFilesExist(in: repoURL, required: ModelNames.Diarizer.requiredModels)
        }
    }

    private func requiredFilesExist(in repoURL: URL, required: Set<String>) -> Bool {
        required.allSatisfy { relativePath in
            let candidate = repoURL.appendingPathComponent(relativePath, isDirectory: true)
            return fileManager.fileExists(atPath: candidate.path)
        }
    }

    // MARK: - Cache cleanup

    private func cleanupStagingCache(for group: ModelGroup) {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let modelsRoot = appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)

        switch group {
        case .asrParakeetV3:
            DownloadUtils.clearModelCache(forRepo: .parakeet, directory: modelsRoot)
        case .vadSilero:
            DownloadUtils.clearModelCache(forRepo: .vad, directory: modelsRoot)
        case .diarization:
            DownloadUtils.clearModelCache(forRepo: .diarizer, directory: modelsRoot)
        }
    }
}
