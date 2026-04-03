import Foundation
import Testing
@testable import Scriberman

struct PromptManagementViewModelTests {
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "PromptManagementViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func cleanupDefaults(named suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test
    @MainActor
    func testLoadPromptsSortsCaseInsensitively() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let store = AIPromptStore(defaults: defaults)
        store.addPrompt(name: "zeta", content: "z")
        store.addPrompt(name: "Alpha", content: "a")
        store.addPrompt(name: "beta", content: "b")

        let viewModel = PromptManagementViewModel(promptStore: store)
        viewModel.loadPrompts()

        #expect(viewModel.prompts.map { $0.name } == ["Alpha", "beta", "zeta"])
    }

    @Test
    @MainActor
    func testPresentEditorPopulatesAndClearsDrafts() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let store = AIPromptStore(defaults: defaults)
        let existing = store.addPrompt(name: "Summary", content: "Summarize")
        let viewModel = PromptManagementViewModel(promptStore: store)

        viewModel.presentEditor(for: existing)
        #expect(viewModel.isEditorPresented)
        #expect(viewModel.editingPromptID == existing.id)
        #expect(viewModel.promptNameDraft == "Summary")
        #expect(viewModel.promptContentDraft == "Summarize")

        viewModel.presentEditor(for: nil as AIPrompt?)
        #expect(viewModel.isEditorPresented)
        #expect(viewModel.editingPromptID == nil)
        #expect(viewModel.promptNameDraft == "")
        #expect(viewModel.promptContentDraft == "")
    }

    @Test
    @MainActor
    func testSavePromptValidatesEmptyName() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let viewModel = PromptManagementViewModel(promptStore: AIPromptStore(defaults: defaults))
        viewModel.presentEditor(for: nil as AIPrompt?)
        viewModel.promptNameDraft = "   "
        viewModel.promptContentDraft = "Content"

        viewModel.savePrompt()

        #expect(viewModel.promptValidationMessage == "Prompt name is required.")
        #expect(viewModel.isEditorPresented)
    }

    @Test
    @MainActor
    func testSavePromptValidatesDuplicateName() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let store = AIPromptStore(defaults: defaults)
        _ = store.addPrompt(name: "Summary", content: "Original")

        let viewModel = PromptManagementViewModel(promptStore: store)
        viewModel.loadPrompts()
        viewModel.presentEditor(for: nil as AIPrompt?)
        viewModel.promptNameDraft = "summary"
        viewModel.promptContentDraft = "New content"

        viewModel.savePrompt()

        #expect(viewModel.promptValidationMessage == "Prompt name must be unique.")
        #expect(viewModel.isEditorPresented)
    }

    @Test
    @MainActor
    func testSavePromptPersistsValidPromptAndDismissesEditor() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let store = AIPromptStore(defaults: defaults)
        let viewModel = PromptManagementViewModel(promptStore: store)

        viewModel.presentEditor(for: nil as AIPrompt?)
        viewModel.promptNameDraft = "  Summary  "
        viewModel.promptContentDraft = "  Summarize this transcript  "

        viewModel.savePrompt()

        #expect(viewModel.isEditorPresented == false)
        #expect(viewModel.promptValidationMessage == nil)
        #expect(viewModel.prompts.count == 1)
        #expect(viewModel.prompts.first?.name == "Summary")
        #expect(viewModel.prompts.first?.content == "Summarize this transcript")
    }

    @Test
    @MainActor
    func testDeletePromptRemovesItemFromList() {
        let (defaults, suiteName) = makeDefaults()
        defer { cleanupDefaults(named: suiteName) }

        let store = AIPromptStore(defaults: defaults)
        let first = store.addPrompt(name: "Summary", content: "A")
        let second = store.addPrompt(name: "Action Items", content: "B")

        let viewModel = PromptManagementViewModel(promptStore: store)
        viewModel.loadPrompts()
        viewModel.deletePrompt(first)

        #expect(viewModel.prompts.map { $0.id } == [second.id])
    }
}
