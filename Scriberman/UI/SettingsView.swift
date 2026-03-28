import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var appState: AppState
    @State private var isModelsExpanded = false

    var body: some View {
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
}
