import FluidAudio
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

    // MARK: - LS-EEND Diarizer

    /// Builds a local `LSEENDModelDescriptor` from workspace-installed model files.
    ///
    /// This method **never** downloads from HuggingFace. If the required files are
    /// absent it throws `TranscriptionError.missingWorkspaceModels` so callers can
    /// surface an actionable message directing the user to Settings → Models to
    /// install the Streaming Diarization model.
    ///
    /// - Parameters:
    ///   - variant: The LS-EEND variant to load (e.g. `.ami`).
    ///   - workspace: The active workspace whose `models/` directory is searched.
    /// - Returns: A descriptor whose `modelURL` and `metadataURL` point to local files.
    /// - Throws: `TranscriptionError.missingWorkspaceModels` if the `.mlmodelc` or
    ///   `.json` file for the requested variant is not present.
    func lseendDescriptor(variant: LSEENDVariant, in workspace: Workspace) throws -> LSEENDModelDescriptor {
        let repoURL = workspace.modelsURL.appendingPathComponent(
            ModelGroup.streamingDiarization.repoFolderName, isDirectory: true
        )
        let modelURL = repoURL.appendingPathComponent(variant.modelFile)
        let metadataURL = repoURL.appendingPathComponent(variant.configFile)

        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw TranscriptionError.missingWorkspaceModels([
                "\(ModelGroup.streamingDiarization.repoFolderName)/\(variant.modelFile)"
            ])
        }
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw TranscriptionError.missingWorkspaceModels([
                "\(ModelGroup.streamingDiarization.repoFolderName)/\(variant.configFile)"
            ])
        }

        return LSEENDModelDescriptor(variant: variant, modelURL: modelURL, metadataURL: metadataURL)
    }
}
