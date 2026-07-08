import Foundation

enum ModelGroup: String, CaseIterable, Identifiable {
    case asrParakeetV3
    case vadSilero
    case offlineDiarization
    case lseendDiarization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asrParakeetV3:
            return "ASR (Parakeet v3)"
        case .vadSilero:
            return "VAD (Silero CoreML)"
        case .offlineDiarization:
            return "Diarization (Global Offline)"
        case .lseendDiarization:
            return "Turn Diarization (LS-EEND)"
        }
    }

    var repoFolderName: String {
        switch self {
        case .asrParakeetV3:
            return "parakeet-tdt-0.6b-v3"
        case .vadSilero:
            return "silero-vad"
        case .offlineDiarization:
            return "speaker-diarization"
        case .lseendDiarization:
            // Matches FluidAudio's Repo.lseendDihard3.folderName so workspace
            // layout mirrors LSEENDModel.loadFromHuggingFace's cache layout.
            return "ls-eend/dih3"
        }
    }
}

enum ModelGroupReadinessState: String {
    case missing
    case downloading
    case ready
    case error
}
