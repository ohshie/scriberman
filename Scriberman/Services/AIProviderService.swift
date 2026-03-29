import Foundation
import Observation
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
}

@MainActor
@Observable
final class AIProviderService: AIProviderServiceProtocol {
    private enum Constants {
        static let keychainKey = "aiProvider.openAI.apiKey"
        static let fallbackModels = ["gpt-5.2"]
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

    private func refreshConfigurationState() {
        isConfigured = Self.isValidAPIKey(store: keychainStore.read(key: Constants.keychainKey))
    }

    private static func isValidAPIKey(store key: String?) -> Bool {
        guard let key else {
            return false
        }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedKey.isEmpty && normalizedKey.hasPrefix("sk-") && normalizedKey.count >= 20
    }
}
