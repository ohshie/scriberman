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

    // MARK: - ASR

    /// Parakeet version installed by `ModelInstallService` and loaded by every ASR path.
    /// `AsrModels.load(from:)` resolves the repo folder from this version, so each load call
    /// must pass it; omitting it resolves (and downloads) v3.
    static let asrModelVersion: AsrModelVersion = .ultra

    // MARK: - Turn diarization (Nemotron 3)

    /// Nemotron 3 preset installed by `ModelInstallService` and run by live transcription.
    /// Only this preset's bundle is downloaded. `low` until the recording comparison picks
    /// between `low` and `fast` (openspec nemotron3-live-turns, D2).
    static let nemotron3Preset: Nemotron3Config = .low

    /// Bundle path relative to the group's repo folder, mirroring the hub layout
    /// (`monolithic/v2/<bundle>.mlmodelc`) that `Nemotron3Models.loadFromHuggingFace` uses.
    static var nemotron3BundleRelativePath: String {
        "\(nemotron3Preset.hubSubdirectory)/\(nemotron3Preset.modelFileName)"
    }

    /// Root-level assets the pinned preset loads next to its bundle.
    static var nemotron3RequiredAssets: Set<String> {
        var assets: Set<String> = [ModelNames.Nemotron3.silenceEmbeddingFile]
        if nemotron3Preset.splitGraph {
            assets.insert(ModelNames.Nemotron3.preEncodeProjectionFile)
        }
        return assets
    }

    /// The preset with `modelFileName` pointing into the hub layout, so
    /// `Nemotron3Models.load(config:directory:)` finds the bundle and the root assets
    /// from the one repo folder. Chunking parameters are the preset's.
    static var nemotron3LoadConfig: Nemotron3Config {
        var config = nemotron3Preset
        config.modelFileName = nemotron3BundleRelativePath
        return config
    }
}
