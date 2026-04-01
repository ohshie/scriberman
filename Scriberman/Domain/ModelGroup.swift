import Foundation

enum ModelGroup: String, CaseIterable, Identifiable {
    case asrParakeetV3
    case vadSilero
    case offlineDiarization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asrParakeetV3:
            return "ASR (Parakeet v3)"
        case .vadSilero:
            return "VAD (Silero CoreML)"
        case .offlineDiarization:
            return "Diarization (Global Offline)"
        }
    }

    var repoFolderName: String {
        switch self {
        case .asrParakeetV3:
            return "parakeet-tdt-0.6b-v3-coreml"
        case .vadSilero:
            return "silero-vad-coreml"
        case .offlineDiarization:
            return "speaker-diarization-coreml"
        }
    }
}

enum ModelGroupReadinessState: String {
    case missing
    case downloading
    case installing
    case ready
    case error
}
