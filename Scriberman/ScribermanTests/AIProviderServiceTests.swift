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

        XCTAssertEqual(service.availableModels, ["gpt-5.2"])
    }

    func testMakeClientReturnsNilWhenNoKeyStored() {
        let service = makeService()
        XCTAssertNil(service.makeClient())
    }

    func testPerformTransformationBuildsExpectedRequestStructure() async {
        let keychainStore = MockKeychainStore()
        try? keychainStore.save(key: "aiProvider.openAI.apiKey", value: "sk-12345678901234567890")
        var capturedQuery: CreateModelResponseQuery?

        let service = makeService(
            keychainStore: keychainStore,
            responseCreator: { _, query in
                capturedQuery = query
                throw TestError.expectedFailure
            }
        )
        service.selectedModelID = "gpt-5.2"

        do {
            _ = try await service.performTransformation(
                transcript: "Transcript body",
                systemPrompt: "Summarize this transcript"
            )
            XCTFail("Expected provider failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Could not transform transcript right now. Check your key/network and try again."
            )
        }

        XCTAssertEqual(capturedQuery?.model, "gpt-5.2")
        XCTAssertEqual(capturedQuery?.instructions, "Summarize this transcript")
        if case let .textInput(input)? = capturedQuery?.input {
            XCTAssertEqual(input, "Transcript body")
        } else {
            XCTFail("Expected text input request")
        }
    }

    func testShouldWarnAboutTranscriptLengthThreshold() {
        let service = makeService()

        XCTAssertFalse(service.shouldWarnAboutTranscriptLength(String(repeating: "a", count: 40_000)))
        XCTAssertTrue(service.shouldWarnAboutTranscriptLength(String(repeating: "a", count: 40_001)))
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

@MainActor
final class AIPromptStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AIPromptStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAddPromptPersistsPrompt() {
        let store = AIPromptStore(defaults: defaults)

        let added = store.addPrompt(name: "Summary", content: "Summarize this transcript")
        let prompts = store.loadPrompts()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first, added)
    }

    func testUpdatePromptUpdatesPersistedPrompt() {
        let store = AIPromptStore(defaults: defaults)
        let added = store.addPrompt(name: "Summary", content: "Summarize")

        store.updatePrompt(id: added.id, name: "Action Items", content: "Extract actions")
        let prompts = store.loadPrompts()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.id, added.id)
        XCTAssertEqual(prompts.first?.name, "Action Items")
        XCTAssertEqual(prompts.first?.content, "Extract actions")
    }

    func testDeletePromptRemovesPromptAndClearsLastUsedWhenNeeded() {
        let store = AIPromptStore(defaults: defaults)
        let first = store.addPrompt(name: "Summary", content: "Summarize")
        let second = store.addPrompt(name: "Action Items", content: "List actions")
        store.setLastUsedPromptID(second.id)

        store.deletePrompt(id: second.id)

        let prompts = store.loadPrompts()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first?.id, first.id)
        XCTAssertNil(store.loadLastUsedPromptID())
    }
}

final class SettingsViewSourceTests: XCTestCase {
    func testSettingsViewUsesTabViewWithGeneralAndPromptsTabs() throws {
        let source = try settingsSource()

        XCTAssertTrue(source.contains("TabView(selection: $selectedTab)"))
        XCTAssertTrue(source.contains("Label(\"General\", systemImage: \"gearshape\")"))
        XCTAssertTrue(source.contains("Label(\"Prompts\", systemImage: \"text.bubble\")"))
    }

    func testPromptsTabSupportsCRUDAndValidationHooks() throws {
        let source = try settingsSource()

        XCTAssertTrue(source.contains("Button(\"Add Prompt\")"))
        XCTAssertTrue(source.contains("Button(\"Edit\")"))
        XCTAssertTrue(source.contains("Button(\"Delete\", role: .destructive)"))
        XCTAssertTrue(source.contains("\"Prompt name is required.\""))
        XCTAssertTrue(source.contains("\"Prompt content is required.\""))
        XCTAssertTrue(source.contains("\"Prompt name must be unique.\""))
        XCTAssertTrue(source.contains("promptStore.addPrompt"))
        XCTAssertTrue(source.contains("promptStore.updatePrompt"))
        XCTAssertTrue(source.contains("promptStore.deletePrompt"))
    }

    private func settingsSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent("../UI/SettingsView.swift")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
