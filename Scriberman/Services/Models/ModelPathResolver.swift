import FluidAudio
import Foundation

/// Resolves model file paths from the workspace for all FluidAudio services.
///
/// `ModelInstallService` installs all models under `<workspace>/models/<group.repoFolderName>/`.
/// Services **must** use this resolver rather than constructing paths independently,
/// providing a single source of truth for where models live and producing clear
/// `TranscriptionError.missingWorkspaceModels` errors when a model hasn't been
/// downloaded yet (directing the user to Settings → Models).
// @unchecked: the only stored property is FileManager.default, which is
// documented thread-safe.
struct ModelPathResolver: @unchecked Sendable {
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

    // MARK: - LS-EEND

    /// LS-EEND variant/step installed by `ModelInstallService` and loaded by
    /// live transcription. Only this one variant is downloaded; the HF repo
    /// carries 4 variants × 5 step sizes.
    static let lseendVariant: LSEENDVariant = .dihard3
    static let lseendStepSize: LSEENDStepSize = .step100ms

    /// Path of the LS-EEND `.mlmodelc` relative to the group's repo folder,
    /// mirroring the layout `LSEENDModel.loadFromHuggingFace` uses.
    static var lseendModelRelativePath: String {
        let relative = lseendVariant.fileName(forStep: lseendStepSize)
        guard let subPath = Repo.lseendDihard3.subPath else {
            return relative
        }
        return "\(subPath)/\(relative)"
    }

    /// Returns the validated LS-EEND `.mlmodelc` URL within `workspace`.
    ///
    /// - Throws: `TranscriptionError.missingWorkspaceModels` if the model is not installed.
    func lseendModelURL(in workspace: Workspace) throws -> URL {
        let directory = try modelDirectory(for: .lseendDiarization, in: workspace)
        let url = directory.appendingPathComponent(Self.lseendModelRelativePath, isDirectory: true)
        guard fileManager.fileExists(atPath: url.path) else {
            throw TranscriptionError.missingWorkspaceModels([ModelGroup.lseendDiarization.repoFolderName])
        }
        return url
    }
}
