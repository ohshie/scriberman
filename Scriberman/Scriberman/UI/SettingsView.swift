import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Workspace") {
                LabeledContent("Current path") {
                    Text(viewModel.workspacePathText)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }

                Text("Recommended location: ~/Documents/Scriberman")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Change Workspace Folder") {
                        pickWorkspaceAndApply()
                    }

                    if appState.workspaceErrorMessage != nil {
                        Button("Re-authorize") {
                            pickWorkspaceAndApply()
                        }
                    }
                }

                if let errorMessage = appState.workspaceErrorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Status") {
                Text(viewModel.workspaceStatusText)
            }
        }
        .formStyle(.grouped)
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
