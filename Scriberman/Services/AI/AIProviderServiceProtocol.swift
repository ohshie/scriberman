import Foundation
import OpenAI

@MainActor
protocol AIProviderServiceProtocol: AnyObject {
    var isEnabled: Bool { get set }
    var isConfigured: Bool { get }
    var selectedProvider: AIProvider { get set }
    var selectedModelID: String? { get set }
    var availableModels: [String] { get }
    var connectionStatus: ConnectionStatus { get }

    func saveAPIKey(_ key: String)
    func makeClient() -> OpenAI?
    func testConnection() async
    func fetchModels() async
    func performTransformation(transcript: String, systemPrompt: String) async throws -> String
    func shouldWarnAboutTranscriptLength(_ transcript: String) -> Bool
}
