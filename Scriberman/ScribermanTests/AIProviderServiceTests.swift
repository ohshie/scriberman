import Foundation
import OpenAI
import XCTest
@testable import Scriberman

@MainActor
final class AIProviderServiceTests: XCTestCase {
    private enum TestError: Error {
        case expectedFailure
    }

    func testIsConfiguredTransitionsForValidInvalidAndDeletedKey() {
        let keychainStore = MockKeychainStore()
        let service = makeService(keychainStore: keychainStore)

        XCTAssertFalse(service.isConfigured)

        service.saveAPIKey("sk-12345678901234567890")
        XCTAssertTrue(service.isConfigured)

        service.saveAPIKey("invalid-key")
        XCTAssertFalse(service.isConfigured)

        service.saveAPIKey("")
        XCTAssertFalse(service.isConfigured)
        XCTAssertEqual(keychainStore.deleteCalls.count, 1)
    }

    func testIsEnabledPersistsToAIProviderStore() {
        let suiteSuffix = "isEnabled"
        let defaults = makeUserDefaults(suffix: suiteSuffix)

        let service = makeService(defaults: defaults)
        XCTAssertFalse(service.isEnabled)

        service.isEnabled = true

        let restored = AIProviderStore(defaults: defaults)
        XCTAssertTrue(restored.isEnabled)
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.\(suiteSuffix)")
    }

    func testConnectionShortCircuitsWithoutConfiguredKeyAndDoesNotCreateClient() async {
        var clientFactoryCalls = 0
        let service = makeService(
            clientFactory: { token in
                clientFactoryCalls += 1
                return OpenAI(apiToken: token)
            }
        )

        await service.testConnection()

        XCTAssertEqual(clientFactoryCalls, 0)
        XCTAssertEqual(service.connectionStatus, .failed("No API key configured"))
    }

    func testFetchModelsFallsBackWhenFetchingThrows() async {
        let keychainStore = MockKeychainStore()
        try? keychainStore.save(key: "aiProvider.openAI.apiKey", value: "sk-12345678901234567890")

        let service = makeService(
            keychainStore: keychainStore,
            modelsFetcher: { _ in throw TestError.expectedFailure }
        )

        await service.fetchModels()

        XCTAssertEqual(service.availableModels, ["gpt-4o", "gpt-4.1", "gpt-4.1-mini"])
    }

    func testMakeClientReturnsNilWhenNoKeyStored() {
        let service = makeService()
        XCTAssertNil(service.makeClient())
    }

    private func makeService(
        keychainStore: MockKeychainStore = MockKeychainStore(),
        defaults: UserDefaults? = nil,
        clientFactory: @escaping (String) -> OpenAI = { OpenAI(apiToken: $0) },
        modelsFetcher: @escaping (OpenAI) async throws -> ModelsResult = { try await $0.models() },
        responseCreator: @escaping (OpenAI, CreateModelResponseQuery) async throws -> ResponseObject = {
            try await $0.responses.createResponse(query: $1)
        }
    ) -> AIProviderService {
        let storeDefaults = defaults ?? makeUserDefaults(suffix: UUID().uuidString)
        let store = AIProviderStore(defaults: storeDefaults)
        return AIProviderService(
            keychainStore: keychainStore,
            store: store,
            clientFactory: clientFactory,
            modelsFetcher: modelsFetcher,
            responseCreator: responseCreator
        )
    }

    private func makeUserDefaults(suffix: String) -> UserDefaults {
        let suiteName = "AIProviderServiceTests.\(suffix)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

}
