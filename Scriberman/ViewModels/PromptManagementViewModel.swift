import Foundation
import Observation

@MainActor
@Observable
final class PromptManagementViewModel {
    private let promptStore: AIPromptStore

    var prompts: [AIPrompt] = []
    var isEditorPresented = false
    var editingPromptID: UUID?
    var promptNameDraft = ""
    var promptContentDraft = ""
    var promptValidationMessage: String?

    init(promptStore: AIPromptStore = AIPromptStore()) {
        self.promptStore = promptStore
    }

    func loadPrompts() {
        prompts = promptStore.loadPrompts().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func presentEditor(for prompt: AIPrompt?) {
        editingPromptID = prompt?.id
        promptNameDraft = prompt?.name ?? ""
        promptContentDraft = prompt?.content ?? ""
        promptValidationMessage = nil
        isEditorPresented = true
    }

    func dismissEditor() {
        isEditorPresented = false
    }

    func savePrompt() {
        let normalizedName = promptNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = promptContentDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedName.isEmpty == false else {
            promptValidationMessage = "Prompt name is required."
            return
        }

        guard normalizedContent.isEmpty == false else {
            promptValidationMessage = "Prompt content is required."
            return
        }

        let lowercasedName = normalizedName.lowercased()
        let hasDuplicateName = prompts.contains { prompt in
            guard prompt.id != editingPromptID else {
                return false
            }
            return prompt.name.lowercased() == lowercasedName
        }

        guard hasDuplicateName == false else {
            promptValidationMessage = "Prompt name must be unique."
            return
        }

        if let editingPromptID {
            promptStore.updatePrompt(id: editingPromptID, name: normalizedName, content: normalizedContent)
        } else {
            promptStore.addPrompt(name: normalizedName, content: normalizedContent)
        }

        dismissEditor()
        loadPrompts()
    }

    func deletePrompt(_ prompt: AIPrompt) {
        promptStore.deletePrompt(id: prompt.id)
        loadPrompts()
    }
}
