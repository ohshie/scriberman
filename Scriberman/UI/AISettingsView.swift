import SwiftUI

struct AISettingsView: View {
    private enum Field: Hashable {
        case apiKey
        case customModel
    }

    @Environment(AIProviderService.self) private var aiProviderService
    @State private var apiKeyDraft = ""
    @State private var lastCommittedAPIKeyDraft = ""
    @State private var customModelDraft = ""
    @State private var customModelErrorMessage: String?
    @State private var isAddingCustomModel = false
    @FocusState private var focusedField: Field?

    var body: some View {
        @Bindable var aiProvider = aiProviderService

        Form {
            Section("AI") {
                Toggle("Enable AI", isOn: $aiProvider.isEnabled)

                LabeledContent("API Key") {
                    SecureField("sk-or-...", text: $apiKeyDraft)
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
                        Text("No models available").tag(nil as String?)
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
                    .disabled(!aiProvider.isConfigured || aiProvider.connectionStatus == .testing || isAddingCustomModel)

                    ConnectionStatusBadge(status: aiProvider.connectionStatus)
                }
            }

            Section("Custom Models") {
                if aiProvider.customModels.isEmpty {
                    Text("No custom models added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(aiProvider.customModels, id: \.self) { modelID in
                        HStack {
                            Text(modelID)
                                .textSelection(.enabled)

                            Spacer()

                            Button {
                                aiProvider.removeCustomModel(modelID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(modelID)")
                        }
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    TextField("provider/model-name", text: $customModelDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .customModel)
                        .disabled(!aiProvider.isConfigured || isAddingCustomModel)

                    Button("Add Model") {
                        addCustomModel()
                    }
                    .disabled(!aiProvider.isConfigured || isAddingCustomModel || normalizedCustomModelDraft.isEmpty)

                    if isAddingCustomModel {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let customModelErrorMessage {
                    Text(customModelErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var normalizedCustomModelDraft: String {
        customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitAPIKeyIfNeeded() {
        let normalized = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != lastCommittedAPIKeyDraft else {
            return
        }

        aiProviderService.saveAPIKey(normalized)
        lastCommittedAPIKeyDraft = normalized
    }

    private func addCustomModel() {
        let modelID = normalizedCustomModelDraft
        guard modelID.isEmpty == false else {
            return
        }

        customModelErrorMessage = nil
        isAddingCustomModel = true

        Task {
            do {
                try await aiProviderService.addCustomModel(modelID)
                await MainActor.run {
                    customModelDraft = ""
                    isAddingCustomModel = false
                }
            } catch {
                await MainActor.run {
                    customModelErrorMessage = error.localizedDescription
                    isAddingCustomModel = false
                }
            }
        }
    }
}
