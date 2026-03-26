import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Models") {
            ForEach(ModelGroup.allCases) { group in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(.body)

                        if let message = viewModel.modelStatusMessages[group] {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Text((viewModel.modelStates[group] ?? .missing).rawValue)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())

                    Button(buttonTitle(for: group)) {
                        Task {
                            await viewModel.downloadTapped(for: group)
                        }
                    }
                    .disabled(!viewModel.canDownloadModels)
                }
            }

            if !viewModel.canDownloadModels {
                Text("Model downloads are disabled until workspace access is configured and active.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func buttonTitle(for group: ModelGroup) -> String {
        if (viewModel.modelStates[group] ?? .missing) == .error {
            return "Retry"
        }

        return "Download"
    }
}
