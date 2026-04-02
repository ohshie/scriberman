import Foundation

@MainActor
final class AIPromptStore {
    private enum Keys {
        static let prompts = "aiPrompts.prompts"
        static let lastUsedPromptID = "aiPrompts.lastUsedPromptID"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPrompts() -> [AIPrompt] {
        guard let data = defaults.data(forKey: Keys.prompts) else {
            return []
        }
        return (try? decoder.decode([AIPrompt].self, from: data)) ?? []
    }

    func savePrompts(_ prompts: [AIPrompt]) {
        if prompts.isEmpty {
            defaults.removeObject(forKey: Keys.prompts)
            defaults.removeObject(forKey: Keys.lastUsedPromptID)
            return
        }

        guard let data = try? encoder.encode(prompts) else {
            return
        }
        defaults.set(data, forKey: Keys.prompts)

        if let lastUsedPromptID = loadLastUsedPromptID(),
           prompts.contains(where: { $0.id == lastUsedPromptID }) == false {
            defaults.removeObject(forKey: Keys.lastUsedPromptID)
        }
    }

    @discardableResult
    func addPrompt(name: String, content: String) -> AIPrompt {
        let prompt = AIPrompt(name: name, content: content)
        var prompts = loadPrompts()
        prompts.append(prompt)
        savePrompts(prompts)
        return prompt
    }

    func updatePrompt(id: UUID, name: String, content: String) {
        var prompts = loadPrompts()
        guard let index = prompts.firstIndex(where: { $0.id == id }) else {
            return
        }
        prompts[index].name = name
        prompts[index].content = content
        savePrompts(prompts)
    }

    func deletePrompt(id: UUID) {
        var prompts = loadPrompts()
        prompts.removeAll { $0.id == id }
        savePrompts(prompts)

        if loadLastUsedPromptID() == id {
            defaults.removeObject(forKey: Keys.lastUsedPromptID)
        }
    }

    func loadLastUsedPromptID() -> UUID? {
        guard let rawValue = defaults.string(forKey: Keys.lastUsedPromptID) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    func setLastUsedPromptID(_ id: UUID?) {
        guard let id else {
            defaults.removeObject(forKey: Keys.lastUsedPromptID)
            return
        }
        defaults.set(id.uuidString, forKey: Keys.lastUsedPromptID)
    }
}
