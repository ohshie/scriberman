import SwiftUI

struct SettingsView: View {
    private enum SettingsTab {
        case general
        case menuBar
        case prompts
        case ai
        case hotkeys
        case advanced
    }

    var viewModel: SettingsViewModel
    var updateService: UpdateService
    @Environment(AppState.self) private var appState
    @Environment(AIProviderService.self) private var aiProviderService
    @State private var selectedTab: SettingsTab = .general
    @State private var isModelsExpanded = false
    @State private var promptVM = PromptManagementViewModel()
    @State private var showResetAllConfirmation = false

    var body: some View {
        @Bindable var bindableViewModel = viewModel

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

                    if !viewModel.canDownloadModels {
                        Section {
                            Text("Downloads are disabled until workspace access is configured and active.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Updates") {
                        LabeledContent("Current version") {
                            Text(updateService.currentVersionText)
                        }

                        Toggle(
                            "Automatically check for updates",
                            isOn: Binding(
                                get: { updateService.automaticallyChecksForUpdates },
                                set: { updateService.automaticallyChecksForUpdates = $0 }
                            )
                        )
                        .disabled(!updateService.isConfigured)

                        Button("Check for Updates…") {
                            updateService.checkForUpdates()
                        }
                        .disabled(!updateService.canCheckForUpdates)

                        if let updateErrorMessage = updateService.errorMessage {
                            Text(updateErrorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        } else if !updateService.isConfigured {
                            Text("Update checks are available in production releases.")
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

                AISettingsView()
                    .tabItem {
                        Label("AI", systemImage: "sparkles")
                    }
                    .tag(SettingsTab.ai)

                Form {
                    Section("Audio Processing") {
                        @Bindable var audioSettings = appState.appAudioSettings
                        HStack {
                            Toggle("Noise Suppression (Voice Processing)", isOn: $audioSettings.voiceProcessingEnabled)
                            Button {
                                appState.appAudioSettings.voiceProcessingEnabled = false
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Reset to default")
                        }
                        Text("Applies hardware noise suppression and echo cancellation to the microphone. Takes effect on the next recording. May add minor latency. Default: Off (disabled).")
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
                                Button {
                                    viewModel.vadThreshold = LiveTranscriptionPipelineSettings.defaults.vadThreshold
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset to default")
                            }
                            Slider(value: $bindableViewModel.vadThreshold, in: 0.50...0.98, step: 0.01)
                            Text("Speech detection sensitivity. Higher values reduce false-positives. Default: 0.85.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Min Speech Duration")
                                Spacer()
                                Text(String(format: "%.2fs", bindableViewModel.vadMinSpeechDuration))
                                    .monospacedDigit()
                                Button {
                                    viewModel.vadMinSpeechDuration = LiveTranscriptionPipelineSettings.defaults.vadMinSpeechDuration
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset to default")
                            }
                            Slider(value: $bindableViewModel.vadMinSpeechDuration, in: 0.10...2.0, step: 0.05)
                            Text("Minimum audio length considered speech. Filters transient noise. Default: 0.30s.")
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
                                Button {
                                    viewModel.asrConfidenceGate = LiveTranscriptionPipelineSettings.defaults.asrConfidenceGate
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset to default")
                            }
                            Slider(value: $bindableViewModel.asrConfidenceGate, in: 0.0...1.0, step: 0.01)
                            Text("Discard transcription results below this confidence level. Higher values reduce hallucinations. Default: Off.")
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
                                Button {
                                    viewModel.asrAmplitudeGate = LiveTranscriptionPipelineSettings.defaults.asrAmplitudeGate
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset to default")
                            }
                            Slider(value: $bindableViewModel.asrAmplitudeGate, in: 0.0...0.10, step: 0.005)
                            Text("Discard near-silent audio before transcription. Filters background noise. Default: Off.")
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
                                Button {
                                    viewModel.speakerThreshold = LiveTranscriptionPipelineSettings.defaults.speakerSimilarityThreshold
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset to default")
                            }
                            Slider(value: $bindableViewModel.speakerThreshold, in: 0.1...0.9, step: 0.01)
                            Text("Lower values are stricter, higher values group more aggressively. Default: 0.65.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("Min Silence Gap")
                                Spacer()
                                Text(String(format: "%.2fs", bindableViewModel.minSilenceGap))
                                    .monospacedDigit()
                                Button {
                                    viewModel.minSilenceGap = LiveTranscriptionPipelineSettings.defaults.minSilenceGap
                                } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset to default")
                            }
                            Slider(value: $bindableViewModel.minSilenceGap, in: 0.1...2.0, step: 0.1)
                            Text("Minimum duration of silence between speaker turns. Default: 0.50s.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Transcript Cleanup") {
                        ForEach($bindableViewModel.cleanupRules) { $rule in
                            HStack {
                                TextField("Text to remove", text: $rule.pattern)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 140)
                                if rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                        .help("Empty rules are ignored")
                                        .accessibilityLabel("Empty rule is ignored")
                                }
                                Picker("Position", selection: $rule.position) {
                                    Text("At start").tag(TranscriptCleanupRule.Position.start)
                                    Text("At end").tag(TranscriptCleanupRule.Position.end)
                                    Text("Anywhere").tag(TranscriptCleanupRule.Position.anywhere)
                                }
                                .labelsHidden()
                                .fixedSize()
                                Toggle("Whole words only", isOn: $rule.wholeWord)
                                Button {
                                    viewModel.cleanupRules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete rule")
                            }
                        }
                        Button {
                            viewModel.cleanupRules.append(TranscriptCleanupRule())
                        } label: {
                            Label("Add Rule", systemImage: "plus")
                        }
                        Text("Removes matching text from live transcripts; a segment left empty is dropped entirely. Rules apply to new recording sessions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        Button("Reset All Pipeline Settings to Defaults", role: .destructive) {
                            showResetAllConfirmation = true
                        }
                    }

                    Section("Speaker Profiles") {
                        SpeakerManagementView(store: viewModel.speakerEmbeddingStore)
                    }
                }
                .formStyle(.grouped)
                .confirmationDialog(
                    "Reset all pipeline settings to their defaults?",
                    isPresented: $showResetAllConfirmation
                ) {
                    Button("Reset All", role: .destructive) {
                        viewModel.resetAllPipelineSettingsToDefaults()
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                }
                .tag(SettingsTab.advanced)

                HotkeySettingsView()
                    .tabItem {
                        Label("Hotkeys", systemImage: "keyboard")
                    }
                    .tag(SettingsTab.hotkeys)
            }
            .navigationTitle("Settings")
        }
        .task(id: aiProviderService.isConfigured) {
            if aiProviderService.isConfigured && aiProviderService.availableModels.isEmpty {
                await aiProviderService.fetchModels()
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
