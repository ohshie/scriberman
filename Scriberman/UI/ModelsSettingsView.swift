import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Models") {
            ForEach(ModelGroup.allCases) { group in
                let state = viewModel.modelStates[group] ?? .missing
                let progress = viewModel.modelDownloadProgress[group]

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

                    statusView(state: state, progress: progress)

                    if !isActiveWorkState(state) {
                        Button(buttonTitle(for: group)) {
                            Task {
                                await viewModel.downloadTapped(for: group)
                            }
                        }
                        .disabled(!viewModel.canDownloadModels)
                    }
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

    @ViewBuilder
    private func statusView(state: ModelGroupReadinessState, progress: Double?) -> some View {
        switch state {
        case .downloading where progress != nil:
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: progress, total: 1.0)
                    .frame(width: 120)
                Text("Downloading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .installing:
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView()
                Text("Installing…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        default:
            Text(state.rawValue)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private func isActiveWorkState(_ state: ModelGroupReadinessState) -> Bool {
        state == .downloading || state == .installing
    }
}
