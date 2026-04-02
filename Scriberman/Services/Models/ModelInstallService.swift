import FluidAudio
import Foundation

enum ModelInstallError: LocalizedError {
    case workspaceNotWritable
    case downloadFailed(ModelGroup, reason: String)
    case validationFailed(ModelGroup, path: URL)

    var errorDescription: String? {
        switch self {
        case .workspaceNotWritable:
            return "Workspace is not writable. Please re-authorize your workspace folder."
        case .downloadFailed(let group, let reason):
            return "Failed to download \(group.title) models.\n\(reason)"
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

        let progressHandler = Self.makeDownloadProgressHandler(downloadProgress: downloadProgress)
        let installedURL = workspace.modelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)

        progress?(.downloading)
        do {
            try removeIfExists(installedURL)
            try await downloadDirectly(for: group, to: workspace.modelsURL, progressHandler: progressHandler)
        } catch {
            throw mapDownloadError(error, for: group)
        }

        let isValid = try validateInstalledRepo(for: group, at: installedURL)
        guard isValid else {
            throw ModelInstallError.validationFailed(group, path: installedURL)
        }

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

    private func downloadDirectly(
        for group: ModelGroup,
        to directory: URL,
        progressHandler: DownloadUtils.ProgressHandler?
    ) async throws {
        switch group {
        case .asrParakeetV3:
            try await DownloadUtils.downloadRepo(.parakeet, to: directory, progressHandler: progressHandler)

        case .vadSilero:
            try await DownloadUtils.downloadRepo(.vad, to: directory, progressHandler: progressHandler)

        case .offlineDiarization:
            try await DownloadUtils.downloadRepo(.diarizer, to: directory, progressHandler: progressHandler)
            try await DownloadUtils.downloadRepo(.diarizer, to: directory, variant: "offline")
        }
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

}

#if DEBUG
extension ModelInstallService {
    func validateInstalledRepoForTesting(for group: ModelGroup, at repoURL: URL) throws -> Bool {
        try validateInstalledRepo(for: group, at: repoURL)
    }
}
#endif
