import SwiftUI

struct ModelsSettingsView: View {
    enum RowIndicator: Equatable {
        case capsule(label: String)
        case determinateProgress(value: Double, phaseLabel: String)
        case indeterminateProgress(phaseLabel: String)
    }

    struct RowPresentation: Equatable {
        let indicator: RowIndicator
        let actionTitle: String?
        let isActionEnabled: Bool
    }

    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ForEach(ModelGroup.allCases) { group in
            let state = viewModel.modelStates[group] ?? .missing
            let progress = viewModel.modelDownloadProgress[group]
            let presentation = Self.makeRowPresentation(
                state: state,
                progress: progress,
                canDownloadModels: viewModel.canDownloadModels
            )

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

                statusView(indicator: presentation.indicator)

                if let actionTitle = presentation.actionTitle {
                    Button(actionTitle) {
                        Task {
                            await viewModel.downloadTapped(for: group)
                        }
                    }
                    .disabled(!presentation.isActionEnabled)
                }
            }
        }
    }

    static func makeRowPresentation(
        state: ModelGroupReadinessState,
        progress: Double?,
        canDownloadModels: Bool
    ) -> RowPresentation {
        switch state {
        case .downloading where progress != nil:
            return RowPresentation(
                indicator: .determinateProgress(value: progress ?? 0, phaseLabel: "Downloading…"),
                actionTitle: nil,
                isActionEnabled: false
            )
        case .installing:
            return RowPresentation(
                indicator: .indeterminateProgress(phaseLabel: "Installing…"),
                actionTitle: nil,
                isActionEnabled: false
            )
        case .error:
            return RowPresentation(
                indicator: .capsule(label: state.rawValue),
                actionTitle: "Retry",
                isActionEnabled: canDownloadModels
            )
        default:
            return RowPresentation(
                indicator: .capsule(label: state.rawValue),
                actionTitle: "Download",
                isActionEnabled: canDownloadModels
            )
        }
    }

    @ViewBuilder
    private func statusView(indicator: RowIndicator) -> some View {
        switch indicator {
        case .determinateProgress(let value, let phaseLabel):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: value, total: 1.0)
                    .frame(width: 120)
                Text(phaseLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .indeterminateProgress(let phaseLabel):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView()
                Text(phaseLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .capsule(let label):
            Text(label)
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: Capsule())
        }
    }
}
