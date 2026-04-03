import Foundation
import OpenAI
import Testing
@testable import Scriberman

@MainActor
final class AIProviderServiceTests {
    private enum TestError: Error {
        case expectedFailure
    }

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

    func testFetchModelsFallsBackWhenFetchingThrows() async {
        let keychainStore = MockKeychainStore()
        try? keychainStore.save(key: "aiProvider.openAI.apiKey", value: "sk-12345678901234567890")

        let service = makeService(
            keychainStore: keychainStore,
            modelsFetcher: { _ in throw TestError.expectedFailure }
        )

        await service.fetchModels()

        #expect(service.availableModels == ["gpt-5.2"])
    }

    @Test

    func testMakeClientReturnsNilWhenNoKeyStored() {
        let service = makeService()
        #expect(service.makeClient() == nil)
    }

    @Test

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
