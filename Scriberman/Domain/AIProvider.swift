import Foundation

enum AIProvider: String, CaseIterable, Equatable {
    case openRouter

    var displayName: String {
        switch self {
        case .openRouter:
            return "OpenRouter"
        }
    }
}

enum ConnectionStatus: Equatable {
    case unknown
    case testing
    case connected(Date)
    case failed(String)
}
