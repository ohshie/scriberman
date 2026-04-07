import SwiftUI

struct SettingsView: View {
    private enum SettingsTab {
        case general
        case menuBar
        case prompts
        case advanced
    }

    private enum Field: Hashable {
        case apiKey
    }

    var viewModel: SettingsViewModel
    @Environment(AppState.self) private var appState
    @Environment(AIProviderService.self) private var aiProviderService
    @State private var selectedTab: SettingsTab = .general
    @State private var isModelsExpanded = false
    @State private var apiKeyDraft = ""
    @State private var lastCommittedAPIKeyDraft = ""
    @State private var promptVM = PromptManagementViewModel()
    @FocusState private var focusedField: Field?

    var body: some View {
        @Bindable var bindableViewModel = viewModel
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
                    Section("Menu Bar") {
                        MenuBarSettingsView(
                            menuBarSettings: appState.menuBarSettings,
                            availableDevices: appState.audioDeviceService.availableDevices,
                            runningApps: appState.appAudioService.runningApps
                        )
                    }
                }
                .formStyle(.grouped)
                .onAppear {
                    appState.audioDeviceService.refreshDevices()
                    appState.appAudioService.refreshRunningApps()
                }
                .tabItem {
                    Label("Menu Bar", systemImage: "menubar.rectangle")
                }
                .tag(SettingsTab.menuBar)

                Form {
                    Section("Saved Prompts") {
                        if promptVM.prompts.isEmpty {
                            Text("No prompts yet. Add a prompt to enable AI transformations.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(promptVM.prompts) { prompt in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(prompt.name)
                                        .font(.headline)
                                    Text(prompt.content)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)

                                    HStack {
                                        Button("Edit") {
                                            promptVM.presentEditor(for: prompt)
                                        }

                                        Button("Delete", role: .destructive) {
                                            promptVM.deletePrompt(prompt)
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }

                        Button("Add Prompt") {
                            promptVM.presentEditor(for: nil)
                        }
                    }
                }
                .formStyle(.grouped)
                .task {
                    promptVM.loadPrompts()
                }
                .tabItem {
                    Label("Prompts", systemImage: "text.bubble")
                }
                .tag(SettingsTab.prompts)

                Form {
                    Section("Audio Processing") {
                        @Bindable var audioSettings = appState.appAudioSettings
                        Toggle("Noise Suppression (Voice Processing)", isOn: $audioSettings.voiceProcessingEnabled)
                        Text("Applies hardware noise suppression and echo cancellation to the microphone. Takes effect on the next recording. May add minor latency.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Recording Pipeline") {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("VAD Threshold")
                                Spacer()
                                Text(String(format: "%.2f", bindableViewModel.vadThreshold))
                                    .monospacedDigit()
                            }
                            Slider(value: $bindableViewModel.vadThreshold, in: 0.50...0.98, step: 0.01)
                            Text("Speech detection sensitivity. Higher values reduce false-positives. Default: 0.85")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Min Speech Duration")
                                Spacer()
                                Text(String(format: "%.2fs", bindableViewModel.vadMinSpeechDuration))
                                    .monospacedDigit()
                            }
                            Slider(value: $bindableViewModel.vadMinSpeechDuration, in: 0.10...2.0, step: 0.05)
                            Text("Minimum audio length considered speech. Filters transient noise. Default: 0.30s")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Confidence Gate")
                                Spacer()
                                if bindableViewModel.asrConfidenceGate == 0.0 {
                                    Text("Off")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(String(format: "%.2f", bindableViewModel.asrConfidenceGate))
                                        .monospacedDigit()
                                }
                            }
                            Slider(value: $bindableViewModel.asrConfidenceGate, in: 0.0...1.0, step: 0.01)
                            Text("Discard transcription results below this confidence level. Higher values reduce hallucinations. Default: Off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Amplitude Gate")
                                Spacer()
                                if bindableViewModel.asrAmplitudeGate == 0.0 {
                                    Text("Off")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(String(format: "%.4f", bindableViewModel.asrAmplitudeGate))
                                        .monospacedDigit()
                                }
                            }
                            Slider(value: $bindableViewModel.asrAmplitudeGate, in: 0.0...0.10, step: 0.005)
                            Text("Discard near-silent audio before transcription. Filters background noise. Default: Off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Diarization Settings") {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Speaker Similarity")
                                Spacer()
                                Text(String(format: "%.2f", bindableViewModel.speakerThreshold))
                                    .monospacedDigit()
                            }
                            Slider(value: $bindableViewModel.speakerThreshold, in: 0.1...0.9, step: 0.01)
                            Text("Lower values are stricter, higher values group more aggressively.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Min Silence Gap")
                                Spacer()
                                Text(String(format: "%.2fs", bindableViewModel.minSilenceGap))
                                    .monospacedDigit()
                            }
                            Slider(value: $bindableViewModel.minSilenceGap, in: 0.1...2.0, step: 0.1)
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
        }
        .sheet(isPresented: Binding(
            get: { promptVM.isEditorPresented },
            set: { promptVM.isEditorPresented = $0 }
        )) {
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

    private var promptEditorTitle: String {
        promptVM.editingPromptID == nil ? "Add Prompt" : "Edit Prompt"
    }

    @ViewBuilder
    private var promptEditorSheet: some View {
        NavigationStack {
            Form {
                Section("Prompt Details") {
                    TextField("Name", text: Binding(
                        get: { promptVM.promptNameDraft },
                        set: { promptVM.promptNameDraft = $0 }
                    ))
                    TextEditor(text: Binding(
                        get: { promptVM.promptContentDraft },
                        set: { promptVM.promptContentDraft = $0 }
                    ))
                        .frame(minHeight: 160)
                }

                if let promptValidationMessage = promptVM.promptValidationMessage {
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
                        promptVM.dismissEditor()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        promptVM.savePrompt()
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}
