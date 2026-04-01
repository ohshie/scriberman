import Foundation

/// Resolves model file paths from the workspace for all FluidAudio services.
///
/// `ModelInstallService` installs all models under `<workspace>/models/<group.repoFolderName>/`.
/// Services **must** use this resolver rather than constructing paths independently,
/// providing a single source of truth for where models live and producing clear
/// `TranscriptionError.missingWorkspaceModels` errors when a model hasn't been
/// downloaded yet (directing the user to Settings → Models).
struct ModelPathResolver {
    private let fileManager = FileManager.default

    // MARK: - General

    /// Returns the validated directory URL for `group` within `workspace`.
    ///
    /// - Throws: `TranscriptionError.missingWorkspaceModels` if the directory does not exist.
    func modelDirectory(for group: ModelGroup, in workspace: Workspace) throws -> URL {
        let url = workspace.modelsURL.appendingPathComponent(group.repoFolderName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw TranscriptionError.missingWorkspaceModels([group.repoFolderName])
        }
        return url
    }

}
