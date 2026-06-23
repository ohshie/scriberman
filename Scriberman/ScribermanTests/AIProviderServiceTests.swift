import Foundation
import OpenAI
import Testing
@testable import Scriberman

@MainActor
final class AIProviderServiceTests {
    private enum TestError: Error {
        case expectedFailure
    }

    private static let validAPIKey = "sk-12345678901234567890"

    @Test

    func testIsConfiguredTransitionsForValidInvalidAndDeletedKey() {
        let keychainStore = MockKeychainStore()
        let service = makeService(keychainStore: keychainStore)

        #expect(!(service.isConfigured))

        service.saveAPIKey("sk-12345678901234567890")
        #expect(service.isConfigured)

        service.saveAPIKey("invalid-key")
        #expect(!(service.isConfigured))

        service.saveAPIKey("")
        #expect(!(service.isConfigured))
        #expect(keychainStore.deleteCalls.count == 1)
    }

    @Test

    func testIsEnabledPersistsToAIProviderStore() {
        let suiteSuffix = "isEnabled"
        let defaults = makeUserDefaults(suffix: suiteSuffix)

        let service = makeService(defaults: defaults)
        #expect(!(service.isEnabled))

        service.isEnabled = true

        let restored = AIProviderStore(defaults: defaults)
        #expect(restored.isEnabled)
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.\(suiteSuffix)")
    }

    @Test

    func testConnectionShortCircuitsWithoutConfiguredKeyAndDoesNotCreateClient() async {
        var clientFactoryCalls = 0
        let service = makeService(
            clientFactory: { token in
                clientFactoryCalls += 1
                return OpenAI(apiToken: token)
            }
        )

        await service.testConnection()

        #expect(clientFactoryCalls == 0)
        #expect(service.connectionStatus == .failed("No API key configured"))
    }

    @Test
    func testConnectionUsesOpenRouterConfiguredClientAndDefaultModel() async throws {
        let keychainStore = MockKeychainStore()
        try keychainStore.save(key: "aiProvider.openAI.apiKey", value: Self.validAPIKey)
        var capturedConfiguration: OpenAI.Configuration?
        var capturedQuery: CreateModelResponseQuery?

        let service = makeService(
            keychainStore: keychainStore,
            responseCreator: { client, query in
                capturedConfiguration = client.configuration
                capturedQuery = query
                return Self.makeResponseObject(text: "ok")
            }
        )

        await service.testConnection()

        #expect(capturedConfiguration?.host == "openrouter.ai")
        #expect(capturedConfiguration?.basePath == "/api/v1")
        #expect(capturedQuery?.model == "openai/gpt-5.4")
        #expect({
            if case .connected = service.connectionStatus { return true }
            return false
        }())
    }

    @Test

    func testFetchModelsCombinesPredefinedAndCustomModelsAndResetsStaleSelection() async {
        let defaults = makeUserDefaults(suffix: "fetchModels")
        var store = AIProviderStore(defaults: defaults)
        store.setCustomModels(["openai/gpt-5-mini"])
        store.setSelectedModelID("gpt-5.2")

        let service = makeService(defaults: defaults)

        await service.fetchModels()

        #expect(service.customModels == ["openai/gpt-5-mini"])
        #expect(
            service.availableModels == [
                "openai/gpt-5.4",
                "google/gemini-flash-latest",
                "anthropic/claude-sonnet-latest",
                "openai/gpt-5-mini"
            ]
        )
        #expect(service.selectedModelID == "openai/gpt-5.4")
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.fetchModels")
    }

    @Test
    func testAddCustomModelSuccessPersistsModelAndSelectsIt() async throws {
        let defaults = makeUserDefaults(suffix: "addCustomModelSuccess")
        let keychainStore = MockKeychainStore()
        try keychainStore.save(key: "aiProvider.openAI.apiKey", value: Self.validAPIKey)
        var capturedQuery: CreateModelResponseQuery?

        let service = makeService(
            keychainStore: keychainStore,
            defaults: defaults,
            responseCreator: { _, query in
                capturedQuery = query
                return Self.makeResponseObject(text: "ok")
            }
        )

        await service.fetchModels()
        try await service.addCustomModel("openai/gpt-5-mini")

        #expect(capturedQuery?.model == "openai/gpt-5-mini")
        #expect(service.customModels == ["openai/gpt-5-mini"])
        #expect(service.availableModels.last == "openai/gpt-5-mini")
        #expect(service.selectedModelID == "openai/gpt-5-mini")
        #expect(AIProviderStore(defaults: defaults).customModels == ["openai/gpt-5-mini"])
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.addCustomModelSuccess")
    }

    @Test
    func testAddCustomModelFailureSurfacesProviderMessageAndDoesNotPersist() async throws {
        let defaults = makeUserDefaults(suffix: "addCustomModelFailure")
        let keychainStore = MockKeychainStore()
        try keychainStore.save(key: "aiProvider.openAI.apiKey", value: Self.validAPIKey)

        let service = makeService(
            keychainStore: keychainStore,
            defaults: defaults,
            responseCreator: { _, _ in
                throw TestError.expectedFailure
            }
        )

        await service.fetchModels()

        do {
            try await service.addCustomModel("openai/gpt-5-mini")
            Issue.record("Expected addCustomModel to fail")
        } catch {
            #expect(error.localizedDescription == TestError.expectedFailure.localizedDescription)
        }

        #expect(service.customModels.isEmpty)
        #expect(AIProviderStore(defaults: defaults).customModels.isEmpty)
        #expect(service.connectionStatus == .failed(TestError.expectedFailure.localizedDescription))
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.addCustomModelFailure")
    }

    @Test
    func testAddCustomModelDuplicateDoesNotInvokeValidationTwice() async throws {
        let defaults = makeUserDefaults(suffix: "addCustomModelDuplicate")
        let keychainStore = MockKeychainStore()
        try keychainStore.save(key: "aiProvider.openAI.apiKey", value: Self.validAPIKey)
        var responseCalls = 0

        let service = makeService(
            keychainStore: keychainStore,
            defaults: defaults,
            responseCreator: { _, _ in
                responseCalls += 1
                return Self.makeResponseObject(text: "ok")
            }
        )

        await service.fetchModels()
        try await service.addCustomModel("openai/gpt-5-mini")
        try await service.addCustomModel("openai/gpt-5-mini")

        #expect(responseCalls == 1)
        #expect(service.customModels == ["openai/gpt-5-mini"])
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.addCustomModelDuplicate")
    }

    @Test
    func testRemoveCustomModelRemovesNonSelectedModel() async {
        let defaults = makeUserDefaults(suffix: "removeCustomModel")
        var store = AIProviderStore(defaults: defaults)
        store.setCustomModels(["openai/gpt-5-mini", "anthropic/claude-haiku-latest"])
        store.setSelectedModelID("openai/gpt-5.4")

        let service = makeService(defaults: defaults)
        await service.fetchModels()
        service.removeCustomModel("anthropic/claude-haiku-latest")

        #expect(service.customModels == ["openai/gpt-5-mini"])
        #expect(service.availableModels.contains("anthropic/claude-haiku-latest") == false)
        #expect(service.selectedModelID == "openai/gpt-5.4")
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.removeCustomModel")
    }

    @Test
    func testRemoveCustomModelResetsSelectedModelWhenRemovedModelWasSelected() async {
        let defaults = makeUserDefaults(suffix: "removeSelectedCustomModel")
        var store = AIProviderStore(defaults: defaults)
        store.setCustomModels(["openai/gpt-5-mini"])
        store.setSelectedModelID("openai/gpt-5-mini")

        let service = makeService(defaults: defaults)
        await service.fetchModels()
        service.removeCustomModel("openai/gpt-5-mini")

        #expect(service.customModels.isEmpty)
        #expect(service.selectedModelID == "openai/gpt-5.4")
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.removeSelectedCustomModel")
    }

    @Test
    func testAIProviderStoreMigratesLegacyOpenAIProviderValueToOpenRouter() {
        let defaults = makeUserDefaults(suffix: "legacyProviderMigration")
        defaults.set("openAI", forKey: "aiProvider.selectedProvider")

        let store = AIProviderStore(defaults: defaults)

        #expect(store.selectedProvider == .openRouter)
        defaults.removePersistentDomain(forName: "AIProviderServiceTests.legacyProviderMigration")
    }

    @Test

    func testPerformTransformationBuildsExpectedRequestStructure() async {
        let keychainStore = MockKeychainStore()
        try? keychainStore.save(key: "aiProvider.openAI.apiKey", value: Self.validAPIKey)
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
            Issue.record("Expected provider failure")
        } catch {
            #expect(
                error.localizedDescription
                    == "Could not transform transcript right now. Check your key/network and try again."
            )
        }

        #expect(capturedQuery?.model == "gpt-5.2")
        #expect(capturedQuery?.instructions == "Summarize this transcript")
        if case let .textInput(input)? = capturedQuery?.input {
            #expect(input == "Transcript body")
        } else {
            Issue.record("Expected text input request")
        }
    }

    @Test

    func testShouldWarnAboutTranscriptLengthThreshold() {
        let service = makeService()

        #expect(!(service.shouldWarnAboutTranscriptLength(String(repeating: "a", count: 40_000))))
        #expect(service.shouldWarnAboutTranscriptLength(String(repeating: "a", count: 40_001)))
    }

    private func makeService(
        keychainStore: MockKeychainStore = MockKeychainStore(),
        defaults: UserDefaults? = nil,
        clientFactory: @escaping (String) -> OpenAI = {
            OpenAI(configuration: .init(token: $0, host: "openrouter.ai", basePath: "/api/v1"))
        },
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

    private static func makeResponseObject(text: String) -> ResponseObject {
        let json = """
        {
          "created_at": 0,
          "error": null,
          "id": "resp_test",
          "incomplete_details": null,
          "instructions": null,
          "max_output_tokens": null,
          "metadata": {},
          "model": "openai/gpt-5.4",
          "object": "response",
          "output": [
            {
              "id": "msg_test",
              "type": "message",
              "role": "assistant",
              "content": [
                {
                  "type": "output_text",
                  "text": "\(text)",
                  "annotations": [],
                  "logprobs": []
                }
              ],
              "status": "completed"
            }
          ],
          "parallel_tool_calls": true,
          "previous_response_id": null,
          "reasoning": null,
          "status": "completed",
          "temperature": null,
          "text": {
            "format": {
              "type": "text"
            }
          },
          "tool_choice": "auto",
          "tools": [],
          "top_p": 1.0,
          "truncation": "disabled",
          "usage": null,
          "user": null
        }
        """

        let data = Data(json.utf8)
        return try! JSONDecoder().decode(ResponseObject.self, from: data)
    }
}

@MainActor
final class AIPromptStoreTests {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!

    init() {
        suiteName = "AIPromptStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    @Test

    func testAddPromptPersistsPrompt() {
        let store = AIPromptStore(defaults: defaults)

        let added = store.addPrompt(name: "Summary", content: "Summarize this transcript")
        let prompts = store.loadPrompts()

        #expect(prompts.count == 1)
        #expect(prompts.first == added)
    }

    @Test

    func testUpdatePromptUpdatesPersistedPrompt() {
        let store = AIPromptStore(defaults: defaults)
        let added = store.addPrompt(name: "Summary", content: "Summarize")

        store.updatePrompt(id: added.id, name: "Action Items", content: "Extract actions")
        let prompts = store.loadPrompts()

        #expect(prompts.count == 1)
        #expect(prompts.first?.id == added.id)
        #expect(prompts.first?.name == "Action Items")
        #expect(prompts.first?.content == "Extract actions")
    }

    @Test

    func testDeletePromptRemovesPromptAndClearsLastUsedWhenNeeded() {
        let store = AIPromptStore(defaults: defaults)
        let first = store.addPrompt(name: "Summary", content: "Summarize")
        let second = store.addPrompt(name: "Action Items", content: "List actions")
        store.setLastUsedPromptID(second.id)

        store.deletePrompt(id: second.id)

        let prompts = store.loadPrompts()
        #expect(prompts.count == 1)
        #expect(prompts.first?.id == first.id)
        #expect(store.loadLastUsedPromptID() == nil)
    }
}

final class SettingsViewSourceTests {
    @Test
    func testSettingsViewUsesTabViewWithGeneralAndPromptsTabs() throws {
        let source = try settingsSource()

        #expect(source.contains("TabView(selection: $selectedTab)"))
        #expect(source.contains("Label(\"General\", systemImage: \"gearshape\")"))
        #expect(source.contains("Label(\"Prompts\", systemImage: \"text.bubble\")"))
    }

    @Test

    func testPromptsTabSupportsCRUDAndValidationHooks() throws {
        let settingsSource = try settingsSource()
        let promptViewModelSource = try promptManagementViewModelSource()

        #expect(settingsSource.contains("Button(\"Add Prompt\")"))
        #expect(settingsSource.contains("Button(\"Edit\")"))
        #expect(settingsSource.contains("Button(\"Delete\", role: .destructive)"))
        #expect(settingsSource.contains("promptVM.savePrompt()"))
        #expect(settingsSource.contains("promptVM.deletePrompt(prompt)"))
        #expect(settingsSource.contains("promptVM.presentEditor(for: nil)"))

        #expect(promptViewModelSource.contains("\"Prompt name is required.\""))
        #expect(promptViewModelSource.contains("\"Prompt content is required.\""))
        #expect(promptViewModelSource.contains("\"Prompt name must be unique.\""))
    }

    private func settingsSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent("../UI/SettingsView.swift")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private func promptManagementViewModelSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent("../ViewModels/PromptManagementViewModel.swift")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
