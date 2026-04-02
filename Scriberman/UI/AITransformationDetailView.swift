import AppKit
import MarkdownUI
import SwiftUI

struct AITransformationDetailView: View {
    let session: any TranscribableSession

    @Binding var selectedTransformationID: UUID?

    @State private var viewModel: TranscriptDetailViewModel
    @State private var showRawMarkdown = false

    init(
        session: any TranscribableSession,
        aiProviderService: AIProviderService,
        selectedTransformationID: Binding<UUID?>
    ) {
        self.session = session
        self._selectedTransformationID = selectedTransformationID
        _viewModel = State(initialValue: TranscriptDetailViewModel(session: session, aiProviderService: aiProviderService))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controlsBar

                if viewModel.prompts.isEmpty {
                    Text("Add prompts in Settings to enable transformations.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if viewModel.shouldWarnAboutTranscriptLength {
                    Text("Transcript is longer than 40,000 characters. The model may fail due to context limits.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if transformations.count > 1 {
                    Picker("History", selection: $selectedTransformationID) {
                        ForEach(transformations) { transformation in
                            Text(transformation.historyLabel).tag(Optional(transformation.id))
                        }
                    }
                    .disabled(viewModel.isRunningTransformation)
                }

                if let transformationErrorMessage = viewModel.transformationErrorMessage {
                    Text(transformationErrorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                transformationContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .safeAreaInset(edge: .top) {
            Toggle(isOn: $showRawMarkdown) {
                Text("Raw Markdown")
                    .font(.subheadline.weight(.medium))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .task {
            viewModel.loadPrompts()
            syncSelectionWithAvailableTransformations()
        }
        .onChange(of: selectedTransformationID) { _, newID in
            viewModel.selectedTransformationID = newID
        }
        .onChange(of: viewModel.selectedTransformationID) { _, newID in
            selectedTransformationID = newID
        }
        .onChange(of: transformations.map(\.id)) { _, _ in
            syncSelectionWithAvailableTransformations()
        }
    }

    @ViewBuilder
    private var transformationContent: some View {
        if viewModel.isRunningTransformation {
            SkeletonView()
                .frame(height: 180)
        } else if let selectedTransformation {
            if showRawMarkdown {
                Text(selectedTransformation.resultText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Markdown(selectedTransformation.resultText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 12) {
            Picker("Prompt", selection: $viewModel.selectedPromptID) {
                ForEach(viewModel.prompts) { prompt in
                    Text(prompt.name).tag(Optional(prompt.id))
                }
            }
            .disabled(viewModel.prompts.isEmpty || viewModel.isRunningTransformation)
            .frame(maxWidth: 320)

            Button(viewModel.runButtonTitle) {
                Task {
                    await viewModel.runTransformation()
                    syncSelectionWithAvailableTransformations()
                }
            }
            .disabled(viewModel.canRunTransformation == false)

            Spacer(minLength: 0)
        }
    }

    private var transformations: [AITransformation] {
        viewModel.availableTransformations
    }

    private var selectedTransformation: AITransformation? {
        if let selectedTransformationID,
           let selected = transformations.first(where: { $0.id == selectedTransformationID }) {
            return selected
        }

        return transformations.last
    }

    private func syncSelectionWithAvailableTransformations() {
        viewModel.refreshSelectedTransformation()
        selectedTransformationID = viewModel.selectedTransformationID
    }

    @ToolbarContentBuilder
    static func toolbarActions(
        onCopy: @escaping () -> Void,
        onExport: @escaping () -> Void
    ) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                onCopy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button {
                onExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
    }
}

private extension AITransformation {
    var historyLabel: String {
        "\(promptName) - \(formattedTime)"
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}
