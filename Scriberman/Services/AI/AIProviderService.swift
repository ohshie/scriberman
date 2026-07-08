import Foundation
import Observation
import OpenAI
import OSLog

@MainActor
@Observable
final class AIProviderService: AIProviderServiceProtocol {
    enum AITransformationError: LocalizedError, Equatable {
        case noAPIKeyConfigured
        case noModelSelected
        case emptyTranscript
        case emptyPrompt
        case noOutput
        case providerFailure(String)
        var errorDescription: String? {
            switch self {
            case .noAPIKeyConfigured:
                return "AI is not configured. Add a valid API key in Settings and try again."
            case .noModelSelected:
                return "No AI model is selected. Choose a model in Settings and try again."
            case .emptyTranscript:
                return "Transcript is empty. Generate a transcript first, then run transformation."
            case .emptyPrompt:
                return "Prompt is empty. Add prompt content before running transformation."
            case .noOutput:
                return "The AI response did not contain text output. Try another prompt."
            case .providerFailure(let message):
                return message
            }
        }
    }

    private enum Constants {
        static let keychainKey = "aiProvider.openAI.apiKey"
        static let predefinedModels = [
            "openai/gpt-5.4",
            "google/gemini-flash-latest",
            "anthropic/claude-sonnet-latest"
        ]
        static let transcriptWarningThreshold = 40_000
        static let transformationFailureMessage = "Could not transform transcript right now. Check your key/network and try again."
    }

    var isEnabled: Bool {
        didSet {
            store.setIsEnabled(isEnabled)
        }
    }

    private(set) var isConfigured: Bool

    var selectedProvider: AIProvider {
        didSet {
            store.setSelectedProvider(selectedProvider)
        }
    }

    var selectedModelID: String? {
        didSet {
            store.setSelectedModelID(selectedModelID)
        }
    }

    private(set) var availableModels: [String] = []
    private(set) var customModels: [String]
    private(set) var connectionStatus: ConnectionStatus = .unknown

    private let keychainStore: KeychainStore
    private var store: AIProviderStore
    private let logger = Logger(subsystem: "Scriberman", category: "AIProviderService")
    private let clientFactory: (String) -> OpenAI
    private let modelsFetcher: (OpenAI) async throws -> ModelsResult
    private let responseCreator: (OpenAI, CreateModelResponseQuery) async throws -> ResponseObject

    init(
        keychainStore: KeychainStore,
        store: AIProviderStore,
        clientFactory: @escaping (String) -> OpenAI = {
            OpenAI(configuration: .init(token: $0, host: "openrouter.ai", basePath: "/api/v1"))
        },
        modelsFetcher: @escaping (OpenAI) async throws -> ModelsResult = { try await $0.models() },
        responseCreator: @escaping (OpenAI, CreateModelResponseQuery) async throws -> ResponseObject = {
            try await $0.responses.createResponse(query: $1)
        }
    ) {
        self.keychainStore = keychainStore
        self.store = store
        self.clientFactory = clientFactory
        self.modelsFetcher = modelsFetcher
        self.responseCreator = responseCreator
        self.isEnabled = store.isEnabled
        self.selectedProvider = store.selectedProvider
        self.selectedModelID = store.selectedModelID
        self.customModels = store.customModels
        self.isConfigured = Self.isValidAPIKey(store: keychainStore.read(key: Constants.keychainKey))
    }

    func saveAPIKey(_ key: String) {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if normalizedKey.isEmpty {
                try keychainStore.delete(key: Constants.keychainKey)
            } else {
                try keychainStore.save(key: Constants.keychainKey, value: normalizedKey)
            }
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }

        refreshConfigurationState()
        Task {
            await fetchModels()
        }
    }

    func addCustomModel(_ modelID: String) async throws {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedModelID.isEmpty == false else {
            throw AITransformationError.providerFailure("Enter a model ID.")
        }
        guard customModels.contains(normalizedModelID) == false else {
            return
        }
        guard let client = makeClient() else {
            connectionStatus = .failed("No API key configured")
            throw AITransformationError.noAPIKeyConfigured
        }

        connectionStatus = .testing
        do {
            let query = CreateModelResponseQuery(
                input: .textInput("Hi"),
                model: normalizedModelID
            )
            _ = try await responseCreator(client, query)

            customModels.append(normalizedModelID)
            store.setCustomModels(customModels)
            refreshAvailableModels()
            selectedModelID = normalizedModelID
            connectionStatus = .connected(Date())
        } catch let error as AITransformationError {
            connectionStatus = .failed(error.localizedDescription)
            throw error
        } catch {
            let message = error.localizedDescription
            connectionStatus = .failed(message)
            throw AITransformationError.providerFailure(message)
        }
    }

    func removeCustomModel(_ modelID: String) {
        let removedSelectedModel = selectedModelID == modelID
        customModels.removeAll { $0 == modelID }
        store.setCustomModels(customModels)
        refreshAvailableModels()

        if removedSelectedModel {
            selectedModelID = availableModels.first
        }
    }

    private func makeClient() -> OpenAI? {
        guard let key = keychainStore.read(key: Constants.keychainKey), !key.isEmpty else {
            return nil
        }
        return clientFactory(key)
    }

    func testConnection() async {
        guard isConfigured else {
            connectionStatus = .failed("No API key configured")
            return
        }
        guard let client = makeClient() else {
            connectionStatus = .failed("No API key configured")
            return
        }

        connectionStatus = .testing
        do {
            let query = CreateModelResponseQuery(
                input: .textInput("Hi"),
                model: "openai/gpt-5.4"
            )
            _ = try await responseCreator(client, query)
            connectionStatus = .connected(Date())
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    func fetchModels() async {
        customModels = store.customModels
        refreshAvailableModels()
    }

    func performTransformation(transcript: String, systemPrompt: String) async throws -> String {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTranscript.isEmpty == false else {
            throw AITransformationError.emptyTranscript
        }

        let normalizedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPrompt.isEmpty == false else {
            throw AITransformationError.emptyPrompt
        }

        guard isConfigured else {
            throw AITransformationError.noAPIKeyConfigured
        }
        guard let client = makeClient() else {
            throw AITransformationError.noAPIKeyConfigured
        }
        guard let modelID = selectedModelID, modelID.isEmpty == false else {
            throw AITransformationError.noModelSelected
        }

        if shouldWarnAboutTranscriptLength(normalizedTranscript) {
            logger.warning("Transcript length warning threshold exceeded: \(normalizedTranscript.count, privacy: .public) chars")
        }

        let query = CreateModelResponseQuery(
            input: .textInput(normalizedTranscript),
            model: modelID,
            instructions: normalizedPrompt
        )

        do {
            let response = try await responseCreator(client, query)
            guard let outputText = Self.extractOutputText(from: response), outputText.isEmpty == false else {
                throw AITransformationError.noOutput
            }
            return outputText
        } catch let error as AITransformationError {
            logger.error("AI transformation failed: \(error.localizedDescription, privacy: .public)")
            throw error
        } catch {
            logger.error("AI transformation request error: \(error.localizedDescription, privacy: .public)")
            throw AITransformationError.providerFailure(Constants.transformationFailureMessage)
        }
    }

    func shouldWarnAboutTranscriptLength(_ transcript: String) -> Bool {
        transcript.count > Constants.transcriptWarningThreshold
    }

    private func refreshConfigurationState() {
        isConfigured = Self.isValidAPIKey(store: keychainStore.read(key: Constants.keychainKey))
    }

    private func refreshAvailableModels() {
        availableModels = Constants.predefinedModels + customModels
        if selectedModelID == nil || !(availableModels.contains(selectedModelID ?? "")) {
            selectedModelID = availableModels.first
        }
    }

    private static func extractOutputText(from response: ResponseObject) -> String? {
        var chunks: [String] = []

        for outputItem in response.output {
            guard case let .outputMessage(message) = outputItem else {
                continue
            }

            for contentItem in message.content {
                switch contentItem {
                case let .outputTextContent(textContent):
                    let text = textContent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty == false {
                        chunks.append(text)
                    }
                case .refusalContent:
                    continue
                }
            }
        }

        let joined = chunks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private static func isValidAPIKey(store key: String?) -> Bool {
        guard let key else {
            return false
        }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedKey.isEmpty && normalizedKey.hasPrefix("sk-") && normalizedKey.count >= 20
    }
}
