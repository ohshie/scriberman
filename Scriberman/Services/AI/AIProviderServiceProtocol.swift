import Foundation

/// What the user asked for, captured when the prompt is picked. Later settings changes do not affect it.
struct AITransformationRequest: Equatable {
    let transcript: String
    let systemPrompt: String
    let promptName: String
    let modelID: String
}

/// The output text plus the metadata of the request that produced it.
struct AITransformationResult: Equatable {
    let text: String
    let promptName: String
    let modelID: String
}

@MainActor
protocol AIProviderServiceProtocol: AnyObject {
    var isEnabled: Bool { get set }
    var isConfigured: Bool { get }
    var selectedProvider: AIProvider { get set }
    var selectedModelID: String? { get set }
    var availableModels: [String] { get }
    var customModels: [String] { get }
    var connectionStatus: ConnectionStatus { get }

    func saveAPIKey(_ key: String)
    func testConnection() async
    func fetchModels() async
    func addCustomModel(_ modelID: String) async throws
    func removeCustomModel(_ modelID: String)
    func performTransformation(_ request: AITransformationRequest) async throws -> AITransformationResult
    func shouldWarnAboutTranscriptLength(_ transcript: String) -> Bool
}
