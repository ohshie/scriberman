import SwiftUI

struct ModelsSettingsView: View {
    var viewModel: SettingsViewModel

    private var missingCount: Int {
        viewModel.modelStates.values.filter { $0 != .ready }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch viewModel.bundlePhase {
            case .idle:
                Text("\(missingCount) of \(ModelGroup.allCases.count) models are not installed.")
                    .foregroundStyle(.secondary)

                Button("Download Models") {
                    Task {
                        await viewModel.downloadAllTapped()
                    }
                }
                .disabled(!viewModel.canDownloadModels)

            case .downloading(let label, let progress):
                ProgressView(value: progress, total: 1.0)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .installing:
                ProgressView()
                Text("Installing…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .warmingUp:
                ProgressView()
                Text("Compiling models for first use…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

            case .allReady:
                Text("✓ All models ready")
                    .foregroundStyle(.secondary)

            case .error(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Retry") {
                    Task {
                        await viewModel.downloadAllTapped()
                    }
                }
                .disabled(!viewModel.canDownloadModels)
            }
        }
    }
}
