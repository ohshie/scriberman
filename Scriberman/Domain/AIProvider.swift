import Foundation

enum AIProvider: String, CaseIterable, Equatable {
    case openAI

    var displayName: String {
        switch self {
        case .openAI:
            return "ChatGPT"
        }
    }
}

enum ConnectionStatus: Equatable {
    case unknown
    case testing
    case connected(Date)
    case failed(String)
}
