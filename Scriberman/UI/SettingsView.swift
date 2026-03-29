import SwiftUI

struct SettingsView: View {
    private enum SettingsTab {
        case general
        case prompts
        case advanced
    }

    private enum Field: Hashable {
        case apiKey
    }

    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(AIProviderService.self) private var aiProviderService
    @State private var selectedTab: SettingsTab = .general
    @State private var isModelsExpanded = false
    @State private var apiKeyDraft = ""
    @State private var lastCommittedAPIKeyDraft = ""
    @State private var promptStore = AIPromptStore()
    @State private var prompts: [AIPrompt] = []
    @State private var isPromptEditorPresented = false
    @State private var editingPromptID: UUID?
    @State private var promptNameDraft = ""
    @State private var promptContentDraft = ""
    @State private var promptValidationMessage: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        @Bindable var aiProvider = aiProviderService

        NavigationStack {
            TabView(selection: $selectedTab) {
                Form {
                    Section("Workspace") {
                        LabeledContent("Path") {
                            Text(viewModel.workspacePathText)
                                .font(.system(.body, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                        }

                        Button("Change Workspace") {
                            pickWorkspaceAndApply()
                        }

                        if let errorMessage = appState.workspaceErrorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("Model") {
                        LabeledContent("Current model") {
                            Text(viewModel.currentModelNameText)
                        }

                        LabeledContent("Status") {
                            Text(viewModel.currentModelStatusText)
                                .foregroundStyle(viewModel.currentModelStatusText == "Installed" ? .green : .secondary)
                        }

                        DisclosureGroup(isExpanded: $isModelsExpanded) {
                            ModelsSettingsView(viewModel: viewModel)
                        } label: {
                            Text("Manage Models")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation {
                                        isModelsExpanded.toggle()
                                    }
                                }
                        }
                    }

                    Section("AI Integration") {
                        Toggle("Enable AI Integration", isOn: $aiProvider.isEnabled)

                        Picker("Provider", selection: $aiProvider.selectedProvider) {
                            ForEach(AIProvider.allCases, id: \.self) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }

                        LabeledContent("API Key") {
                            SecureField("sk-...", text: $apiKeyDraft)
                                .focused($focusedField, equals: .apiKey)
                                .onSubmit {
                                    commitAPIKeyIfNeeded()
                                }
                                .onChange(of: focusedField) { _, newValue in
                                    if newValue != .apiKey {
                                        commitAPIKeyIfNeeded()
                                    }
                                }
                        }

                        Picker("Model", selection: $aiProvider.selectedModelID) {
                            if aiProvider.availableModels.isEmpty {
                                Text("Loading models…").tag(nil as String?)
                            } else {
                                ForEach(aiProvider.availableModels, id: \.self) { modelID in
                                    Text(modelID).tag(Optional(modelID))
                                }
                            }
                        }
                        .disabled(!aiProvider.isConfigured || aiProvider.availableModels.isEmpty)

                        HStack {
                            Button("Test Connection") {
                                Task {
                                    await aiProvider.testConnection()
                                }
                            }
                            .disabled(!aiProvider.isConfigured || aiProvider.connectionStatus == .testing)

                            ConnectionStatusBadge(status: aiProvider.connectionStatus)
                        }
                    }

                    if !viewModel.canDownloadModels {
                        Section {
                            Text("Downloads are disabled until workspace access is configured and active.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

                Form {
                    Section("Saved Prompts") {
                        if prompts.isEmpty {
                            Text("No prompts yet. Add a prompt to enable AI transformations.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(prompts) { prompt in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(prompt.name)
                                        .font(.headline)
                                    Text(prompt.content)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)

                                    HStack {
                                        Button("Edit") {
                                            presentPromptEditor(for: prompt)
                                        }

                                        Button("Delete", role: .destructive) {
                                            deletePrompt(prompt)
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }

                        Button("Add Prompt") {
                            presentPromptEditor(for: nil)
                        }
                    }
                }
                .formStyle(.grouped)
                .tabItem {
                    Label("Prompts", systemImage: "text.bubble")
                }
                .tag(SettingsTab.prompts)

                Form {
                    Section("Diarization Settings") {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Speaker Similarity")
                                Spacer()
                                Text(String(format: "%.2f", viewModel.speakerThreshold))
                                    .monospacedDigit()
                            }
                            Slider(value: $viewModel.speakerThreshold, in: 0.1...0.9, step: 0.01)
                            Text("Lower values are stricter, higher values group more aggressively.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Min Silence Gap")
                                Spacer()
                                Text(String(format: "%.2fs", viewModel.minSilenceGap))
                                    .monospacedDigit()
                            }
                            Slider(value: $viewModel.minSilenceGap, in: 0.1...2.0, step: 0.1)
                            Text("Minimum duration of silence between speaker turns.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Speaker Profiles") {
                        SpeakerManagementView(store: viewModel.speakerEmbeddingStore)
                    }
                }
                .formStyle(.grouped)
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(SettingsTab.advanced)
            }
            .navigationTitle("Settings")
        }
        .task(id: aiProvider.isConfigured) {
            if aiProvider.isConfigured && aiProvider.availableModels.isEmpty {
                await aiProvider.fetchModels()
            }
        }
        .task {
            await viewModel.refresh()
            _ = await appState.verifyWorkspaceForWrite()
            await viewModel.refresh()
            loadPrompts()
        }
        .sheet(isPresented: $isPromptEditorPresented) {
            promptEditorSheet
        }
    }

    private func pickWorkspaceAndApply() {
        Task {
            guard let url = await MainActor.run(body: {
                WorkspacePicker.chooseWorkspaceFolder()
            }) else {
                return
            }

            await appState.selectWorkspace(url: url)
            await viewModel.refresh()
        }
    }

    private func commitAPIKeyIfNeeded() {
        let normalized = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != lastCommittedAPIKeyDraft else {
            return
        }
        aiProviderService.saveAPIKey(normalized)
        lastCommittedAPIKeyDraft = normalized
    }

    private func loadPrompts() {
        prompts = promptStore.loadPrompts().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func presentPromptEditor(for prompt: AIPrompt?) {
        editingPromptID = prompt?.id
        promptNameDraft = prompt?.name ?? ""
        promptContentDraft = prompt?.content ?? ""
        promptValidationMessage = nil
        isPromptEditorPresented = true
    }

    private func savePromptFromEditor() {
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

        isPromptEditorPresented = false
        loadPrompts()
    }

    private func deletePrompt(_ prompt: AIPrompt) {
        promptStore.deletePrompt(id: prompt.id)
        loadPrompts()
    }

    private var promptEditorTitle: String {
        editingPromptID == nil ? "Add Prompt" : "Edit Prompt"
    }

    @ViewBuilder
    private var promptEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Prompt Details") {
                    TextField("Name", text: $promptNameDraft)
                    TextEditor(text: $promptContentDraft)
                        .frame(minHeight: 160)
                }

                if let promptValidationMessage {
                    Section {
                        Text(promptValidationMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(promptEditorTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPromptEditorPresented = false
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePromptFromEditor()
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct ConnectionStatusBadge: View {
    let status: ConnectionStatus

    var body: some View {
        switch status {
        case .unknown:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
