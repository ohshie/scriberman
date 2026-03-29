import SwiftUI

struct SettingsView: View {
    private enum Field: Hashable {
        case apiKey
    }

    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(AIProviderService.self) private var aiProviderService
    @State private var isModelsExpanded = false
    @State private var apiKeyDraft = ""
    @State private var lastCommittedAPIKeyDraft = ""
    @FocusState private var focusedField: Field?

    var body: some View {
        @Bindable var aiProvider = aiProviderService

        NavigationStack {
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
