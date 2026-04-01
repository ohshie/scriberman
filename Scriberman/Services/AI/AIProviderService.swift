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
        case providerFailure
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
            case .providerFailure:
                return "Could not transform transcript right now. Check your key/network and try again."
            }
        }
    }

    private enum Constants {
        static let keychainKey = "aiProvider.openAI.apiKey"
        static let fallbackModels = ["gpt-5.2"]
        static let transcriptWarningThreshold = 40_000
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
        clientFactory: @escaping (String) -> OpenAI = { OpenAI(apiToken: $0) },
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

    func makeClient() -> OpenAI? {
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
                model: .gpt4_1_nano
            )
            _ = try await responseCreator(client, query)
            connectionStatus = .connected(Date())
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    func fetchModels() async {
        availableModels = Constants.fallbackModels
        if selectedModelID == nil || !(availableModels.contains(selectedModelID ?? "")) {
            selectedModelID = availableModels.first
        }
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
            throw AITransformationError.providerFailure
        }
    }

    func shouldWarnAboutTranscriptLength(_ transcript: String) -> Bool {
        transcript.count > Constants.transcriptWarningThreshold
    }

    private func refreshConfigurationState() {
        isConfigured = Self.isValidAPIKey(store: keychainStore.read(key: Constants.keychainKey))
    }

    private static func extractOutputText(from response: ResponseObject) -> String? {
        var chunks: [String] = []

        for outputItem in response.output {
            guard case let .outputMessage(message) = outputItem else {
                continue
            }

            for contentItem in message.content {
                switch contentItem {
                case let .OutputTextContent(textContent):
                    let text = textContent.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty == false {
                        chunks.append(text)
                    }
                case .RefusalContent:
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
