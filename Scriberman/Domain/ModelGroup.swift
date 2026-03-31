import Foundation

enum ModelGroup: String, CaseIterable, Identifiable {
    case asrParakeetV3
    case vadSilero
    case diarization
    case offlineDiarization
    case streamingAsr
    case streamingDiarization

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asrParakeetV3:
            return "ASR (Parakeet v3)"
        case .vadSilero:
            return "VAD (Silero CoreML)"
        case .diarization:
            return "Diarization (Online)"
        case .offlineDiarization:
            return "Diarization (Global Offline)"
        case .streamingAsr:
            return "Streaming ASR"
        case .streamingDiarization:
            return "Streaming Diarization"
        }
    }

    var repoFolderName: String {
        switch self {
        case .asrParakeetV3:
            return "parakeet-tdt-0.6b-v3-coreml"
        case .vadSilero:
            return "silero-vad-coreml"
        case .diarization:
            return "speaker-diarization-coreml"
        case .offlineDiarization:
            return "speaker-diarization-coreml"
        case .streamingAsr:
            return "parakeet-eou-streaming/320ms"
        case .streamingDiarization:
            return "ls-eend"
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
