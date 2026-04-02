import FluidAudio
import Foundation

enum ModelInstallError: LocalizedError {
    case workspaceNotWritable
    case stagingUnavailable
    case downloadFailed(ModelGroup, reason: String)
    case stagedRepositoryNotFound(ModelGroup, searched: [String])
    case validationFailed(ModelGroup, path: URL)

    var errorDescription: String? {
        switch self {
        case .workspaceNotWritable:
            return "Workspace is not writable. Please re-authorize your workspace folder."
        case .stagingUnavailable:
            return "Could not resolve a writable FluidAudio staging directory."
        case .downloadFailed(let group, let reason):
            return "Failed to download \(group.title) models.\n\(reason)"
        case .stagedRepositoryNotFound(let group, let searched):
            let searchSummary = searched.joined(separator: "\n")
            return "Could not locate staged model repo for \(group.title).\nSearched:\n\(searchSummary)"
        case .validationFailed(let group, let path):
            return "Installed files for \(group.title) are incomplete at \(path.path)."
        }
    }
}

protocol ModelInstallServicing: Actor {
    func canInstallModels() async -> Bool
    func state(for group: ModelGroup) async -> ModelGroupReadinessState
    func installModelGroup(
        _ group: ModelGroup,
        progress: (@Sendable (ModelGroupReadinessState) -> Void)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL
    func warmUpModels(workspace: Workspace) async
}

actor ModelInstallService: ModelInstallServicing {
    private let workspaceService: WorkspaceService
    private let fileManager = FileManager.default
    private let modelPathResolver = ModelPathResolver()

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

    func warmUpModels(workspace: Workspace) async {
        do {
            let asrDirectory = try modelPathResolver.modelDirectory(for: .asrParakeetV3, in: workspace)
            _ = try await AsrModels.load(from: asrDirectory)

            let diarizerDirectory = try modelPathResolver.modelDirectory(for: .offlineDiarization, in: workspace)
            let segmentationURL = diarizerDirectory.appendingPathComponent("pyannote_segmentation.mlmodelc", isDirectory: true)
            let embeddingURL = diarizerDirectory.appendingPathComponent("wespeaker_v2.mlmodelc", isDirectory: true)
            _ = try await DiarizerModels.load(
                localSegmentationModel: segmentationURL,
                localEmbeddingModel: embeddingURL
            )
        } catch {
            NSLog("[ModelInstallService] CoreML warm-up failed (non-fatal): %@", String(describing: error))
        }
    }

    @discardableResult
    func installModelGroup(
        _ group: ModelGroup,
        progress: (@Sendable (ModelGroupReadinessState) -> Void)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let workspace: Workspace
        do {
            workspace = try await ensureWorkspaceWriteAccess()
        } catch {
            throw ModelInstallError.workspaceNotWritable
        }

        // Best-effort pre-cleanup so stale staged repos never short-circuit a fresh install.
        cleanupStagingCache(for: group)

        let progressHandler = Self.makeDownloadProgressHandler(downloadProgress: downloadProgress)

        progress?(.downloading)
        do {
            try await triggerFluidAudioDownload(for: group, progressHandler: progressHandler)
        } catch {
            throw mapDownloadError(error, for: group)
        }

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

    private func mapDownloadError(_ error: Error, for group: ModelGroup) -> Error {
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            let failingHost = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?
                .host ?? (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? String)

            let urlError = URLError.Code(rawValue: nsError.code)
            switch urlError {
            case .cannotFindHost, .dnsLookupFailed:
                return ModelInstallError.downloadFailed(
                    group,
                    reason: "DNS lookup failed for \(failingHost ?? "remote host"). Check internet access, DNS, VPN/proxy settings, then retry."
                )
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut:
                return ModelInstallError.downloadFailed(
                    group,
                    reason: "Network connection to model host failed (\(failingHost ?? "unknown host")). Check connectivity and retry."
                )
            default:
                break
            }
        }

        return ModelInstallError.downloadFailed(group, reason: error.localizedDescription)
    }

    // MARK: - Download (FluidAudio helpers)

    static func normalizedDownloadProgress(from fractionCompleted: Double) -> Double {
        min(fractionCompleted * 2.0, 1.0)
    }

    static func makeDownloadProgressHandler(
        downloadProgress: (@Sendable (Double) -> Void)?
    ) -> DownloadUtils.ProgressHandler? {
        guard let downloadProgress else {
            return nil
        }

        return { progress in
            downloadProgress(normalizedDownloadProgress(from: progress.fractionCompleted))
        }
    }

    private func triggerFluidAudioDownload(
        for group: ModelGroup,
        progressHandler: DownloadUtils.ProgressHandler?
    ) async throws {
        let stagingRoot = try preparePrimaryStagingRoot()

        switch group {
        case .asrParakeetV3:
            try await DownloadUtils.downloadRepo(.parakeet, to: stagingRoot, progressHandler: progressHandler)

        case .vadSilero:
            try await DownloadUtils.downloadRepo(.vad, to: stagingRoot, progressHandler: progressHandler)

        case .offlineDiarization:
            try await DownloadUtils.downloadRepo(.diarizer, to: stagingRoot, progressHandler: progressHandler)
            try await DownloadUtils.downloadRepo(.diarizer, to: stagingRoot, variant: "offline")
        }
    }

    private func preparePrimaryStagingRoot() throws -> URL {
        guard let root = stagingSearchRoots().first else {
            throw ModelInstallError.stagingUnavailable
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
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
        let finalURL = workspaceModelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)
        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let partialURL = workspaceModelsURL.appendingPathComponent("\(group.repoFolderName.replacingOccurrences(of: "/", with: "_")).partial", isDirectory: true)
        let backupURL = workspaceModelsURL.appendingPathComponent("\(group.repoFolderName.replacingOccurrences(of: "/", with: "_")).backup", isDirectory: true)

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
            let modelFilesPresent = requiredFilesExist(in: repoURL, required: ModelNames.ASR.requiredModels)
            let vocabName = ModelNames.ASR.vocabulary(for: .parakeet)
            let vocabPresent = fileManager.fileExists(
                atPath: repoURL.appendingPathComponent(vocabName, isDirectory: false).path
            )
            return modelFilesPresent && vocabPresent

        case .vadSilero:
            return requiredFilesExist(in: repoURL, required: ModelNames.VAD.requiredModels)

        case .offlineDiarization:
            return requiredFilesExist(in: repoURL, required: ModelNames.Diarizer.requiredModels)
                && requiredFilesExist(in: repoURL, required: ModelNames.OfflineDiarizer.requiredModels)
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
        let roots = stagingSearchRoots()
        guard !roots.isEmpty else { return }

        let repoName: Repo
        switch group {
        case .asrParakeetV3:
            repoName = .parakeet
        case .vadSilero:
            repoName = .vad
        case .offlineDiarization:
            repoName = .diarizer
        }

        for root in roots {
            DownloadUtils.clearModelCache(forRepo: repoName, directory: root)

            let directRepo = root.appendingPathComponent(group.repoFolderName, isDirectory: true)
            let partialRepo = root.appendingPathComponent("\(group.repoFolderName.replacingOccurrences(of: "/", with: "_")).partial", isDirectory: true)
            let backupRepo = root.appendingPathComponent("\(group.repoFolderName.replacingOccurrences(of: "/", with: "_")).backup", isDirectory: true)

            do {
                try removeIfExists(directRepo)
            } catch {
                NSLog("[ModelInstallService] Failed to remove staged repo at %@: %@", directRepo.path, String(describing: error))
            }

            do {
                try removeIfExists(partialRepo)
            } catch {
                NSLog("[ModelInstallService] Failed to remove partial repo at %@: %@", partialRepo.path, String(describing: error))
            }

            do {
                try removeIfExists(backupRepo)
            } catch {
                NSLog("[ModelInstallService] Failed to remove backup repo at %@: %@", backupRepo.path, String(describing: error))
            }

            if fileManager.fileExists(atPath: directRepo.path) {
                NSLog("[ModelInstallService] Staged repo still exists after cleanup: %@", directRepo.path)
            }
        }
    }
}

#if DEBUG
extension ModelInstallService {
    func validateInstalledRepoForTesting(for group: ModelGroup, at repoURL: URL) throws -> Bool {
        try validateInstalledRepo(for: group, at: repoURL)
    }
}
#endif
