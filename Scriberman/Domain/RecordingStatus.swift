import Foundation

enum RecordingStatus: Equatable, Codable {
    case recorded
    case transcribing
    case done
    case error(String)

    var persistedValue: String {
        switch self {
        case .recorded:
            return "recorded"
        case .transcribing:
            return "transcribing"
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
        case "transcribing":
            self = .transcribing
        case "done":
            self = .done
        case "error":
            self = .error(errorMessage ?? "Unknown error")
        default:
            self = .recorded
        }
    }
}
