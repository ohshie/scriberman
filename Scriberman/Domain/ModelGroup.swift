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
            return "parakeet-tdt-0.6b-v3"
        case .vadSilero:
            return "silero-vad"
        case .offlineDiarization:
            return "speaker-diarization"
        }
    }
}

enum ModelGroupReadinessState: String {
    case missing
    case downloading
    case ready
    case error
}
