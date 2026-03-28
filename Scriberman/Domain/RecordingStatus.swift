import Foundation

enum RecordingStatus: Equatable, Codable {
    case recorded
    case converting
    case transcribing
    case retranscribing
    case done
    case error(String)

    var persistedValue: String {
        switch self {
        case .recorded:
            return "recorded"
        case .converting:
            return "converting"
        case .transcribing:
            return "transcribing"
        case .retranscribing:
            return "retranscribing"
        case .done:
            return "done"
        case .error:
            return "error"
        }
    }

    init(persistedValue: String, errorMessage: String?) {
        switch persistedValue {
        case "recorded":
            self = .recorded
        case "converting":
            self = .converting
        case "transcribing":
            self = .transcribing
        case "retranscribing":
            self = .retranscribing
        case "done":
            self = .done
        case "error":
            self = .error(errorMessage ?? "Unknown error")
        default:
            self = .recorded
        }
    }
}
