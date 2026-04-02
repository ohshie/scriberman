import XCTest
@testable import Scriberman

@MainActor
final class PromptManagementViewModelTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PromptManagementViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadPromptsSortsCaseInsensitively() {
        let store = AIPromptStore(defaults: defaults)
        store.addPrompt(name: "zeta", content: "z")
        store.addPrompt(name: "Alpha", content: "a")
        store.addPrompt(name: "beta", content: "b")

        let viewModel = PromptManagementViewModel(promptStore: store)

        viewModel.loadPrompts()

        XCTAssertEqual(viewModel.prompts.map(\.name), ["Alpha", "beta", "zeta"])
    }

    func testPresentEditorPopulatesAndClearsDrafts() {
        let store = AIPromptStore(defaults: defaults)
        let existing = store.addPrompt(name: "Summary", content: "Summarize")
        let viewModel = PromptManagementViewModel(promptStore: store)

        viewModel.presentEditor(for: existing)

        XCTAssertTrue(viewModel.isEditorPresented)
        XCTAssertEqual(viewModel.editingPromptID, existing.id)
        XCTAssertEqual(viewModel.promptNameDraft, "Summary")
        XCTAssertEqual(viewModel.promptContentDraft, "Summarize")

        viewModel.presentEditor(for: nil)

        XCTAssertTrue(viewModel.isEditorPresented)
        XCTAssertNil(viewModel.editingPromptID)
        XCTAssertEqual(viewModel.promptNameDraft, "")
        XCTAssertEqual(viewModel.promptContentDraft, "")
    }

    func testSavePromptValidatesEmptyName() {
        let viewModel = PromptManagementViewModel(promptStore: AIPromptStore(defaults: defaults))
        viewModel.presentEditor(for: nil)
        viewModel.promptNameDraft = "   "
        viewModel.promptContentDraft = "Content"

        viewModel.savePrompt()

        XCTAssertEqual(viewModel.promptValidationMessage, "Prompt name is required.")
        XCTAssertTrue(viewModel.isEditorPresented)
    }

    func testSavePromptValidatesDuplicateName() {
        let store = AIPromptStore(defaults: defaults)
        _ = store.addPrompt(name: "Summary", content: "Original")

        let viewModel = PromptManagementViewModel(promptStore: store)
        viewModel.loadPrompts()
        viewModel.presentEditor(for: nil)
        viewModel.promptNameDraft = "summary"
        viewModel.promptContentDraft = "New content"

        viewModel.savePrompt()

        XCTAssertEqual(viewModel.promptValidationMessage, "Prompt name must be unique.")
        XCTAssertTrue(viewModel.isEditorPresented)
    }

    func testSavePromptPersistsValidPromptAndDismissesEditor() {
        let store = AIPromptStore(defaults: defaults)
        let viewModel = PromptManagementViewModel(promptStore: store)

        viewModel.presentEditor(for: nil)
        viewModel.promptNameDraft = "  Summary  "
        viewModel.promptContentDraft = "  Summarize this transcript  "

        viewModel.savePrompt()

        XCTAssertFalse(viewModel.isEditorPresented)
        XCTAssertNil(viewModel.promptValidationMessage)
        XCTAssertEqual(viewModel.prompts.count, 1)
        XCTAssertEqual(viewModel.prompts.first?.name, "Summary")
        XCTAssertEqual(viewModel.prompts.first?.content, "Summarize this transcript")
    }

    func testDeletePromptRemovesItemFromList() {
        let store = AIPromptStore(defaults: defaults)
        let first = store.addPrompt(name: "Summary", content: "A")
        let second = store.addPrompt(name: "Action Items", content: "B")

        let viewModel = PromptManagementViewModel(promptStore: store)
        viewModel.loadPrompts()

        viewModel.deletePrompt(first)

        XCTAssertEqual(viewModel.prompts.map(\.id), [second.id])
    }
}
