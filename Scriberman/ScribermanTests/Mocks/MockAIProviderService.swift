import Foundation
@testable import Scriberman

@MainActor
final class MockAIProviderService: AIProviderServiceProtocol {
    var isEnabled = false
    var isConfigured = false
    var selectedProvider: AIProvider = .openRouter
    var selectedModelID: String?
    var availableModels: [String] = []
    var customModels: [String] = []
    var connectionStatus: ConnectionStatus = .unknown

    var saveAPIKeyCalls: [String] = []
    var testConnectionCallCount = 0
    var fetchModelsCallCount = 0
    var addCustomModelCalls: [String] = []
    var removeCustomModelCalls: [String] = []
    var performedTransformations: [(transcript: String, systemPrompt: String)] = []

    var transformationResult = ""
    var addCustomModelError: Error?
    var transformationError: Error?

    func saveAPIKey(_ key: String) {
        saveAPIKeyCalls.append(key)
    }

    func testConnection() async {
        testConnectionCallCount += 1
    }

    func fetchModels() async {
        fetchModelsCallCount += 1
    }

    func addCustomModel(_ modelID: String) async throws {
        addCustomModelCalls.append(modelID)
        if let addCustomModelError {
            throw addCustomModelError
        }

        if customModels.contains(modelID) == false {
            customModels.append(modelID)
        }
        if availableModels.contains(modelID) == false {
            availableModels.append(modelID)
        }
        selectedModelID = modelID
    }

    func removeCustomModel(_ modelID: String) {
        removeCustomModelCalls.append(modelID)
        customModels.removeAll { $0 == modelID }
        availableModels.removeAll { $0 == modelID }
        if selectedModelID == modelID {
            selectedModelID = availableModels.first
        }
    }

    func performTransformation(transcript: String, systemPrompt: String) async throws -> String {
        performedTransformations.append((transcript, systemPrompt))
        if let transformationError {
            throw transformationError
        }
        return transformationResult
    }

    func shouldWarnAboutTranscriptLength(_ transcript: String) -> Bool {
        transcript.count > 40_000
    }
}
