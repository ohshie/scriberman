import AppKit
import SwiftUI

struct TranscriptDetailView: View {
    let session: any TranscribableSession
    let onReprocess: (() -> Void)?
    let onDelete: () -> Void
    let onOpenStudy: (() -> Void)?

    @State private var showingDeleteConfirmation = false
    @State private var viewModel: TranscriptDetailViewModel

    init(
        session: any TranscribableSession,
        aiProviderService: AIProviderService,
        onReprocess: (() -> Void)?,
        onDelete: @escaping () -> Void,
        onOpenStudy: (() -> Void)?
    ) {
        self.session = session
        self.onReprocess = onReprocess
        self.onDelete = onDelete
        self.onOpenStudy = onOpenStudy
        _viewModel = State(initialValue: TranscriptDetailViewModel(session: session, aiProviderService: aiProviderService))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                aiTransformationSection
                transcriptBody
                metadataGrid
                deleteButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let onReprocess {
                    Button {
                        onReprocess()
                    } label: {
                        if viewModel.isReprocessing {
                            Label("Reprocessing", systemImage: "hourglass")
                        } else {
                            Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(!viewModel.canReprocess)
                }

                Button {
                    copyTranscript()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        .alert("Delete Entry", isPresented: $showingDeleteConfirmation) {
            Button("Delete Entry", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes the selected session.")
        }
        .task {
            viewModel.loadPrompts()
            viewModel.refreshSelectedTransformation()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.title)
                .font(.largeTitle.weight(.semibold))

            Text(formattedDate)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            TranscriptPreviewView(
                blocks: transcriptBlocks,
                onTap: viewModel.displayedTranscript == nil ? nil : onOpenStudy
            )
        }
    }

    private var transcriptBlocks: [TranscriptBlock] {
        guard let transcript = viewModel.displayedTranscript else { return [] }
        return TranscriptGrouper.makeBlocks(from: transcript)
    }

    private var aiTransformationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI Transformations")
                    .font(.title3.weight(.semibold))
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 12) {
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
                    }
                }
                .disabled(viewModel.canRunTransformation == false)
            }

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

            if viewModel.availableTransformations.isEmpty == false {
                Picker("History", selection: $viewModel.selectedTransformationID) {
                    ForEach(viewModel.availableTransformations) { transformation in
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

            if viewModel.isRunningTransformation {
                SkeletonView()
                    .frame(height: 180)
            } else if let selectedTransformation = viewModel.selectedTransformation {
                sectionCard(title: selectedTransformation.promptName, text: selectedTransformation.resultText)
            } else {
                sectionCard(title: "Result", text: "Run a transformation to see AI output here.")
            }
        }
    }

    private var metadataGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .leading)
        ], alignment: .leading, spacing: 16) {
            metadataCell(
                title: "Application",
                value: viewModel.applicationName ?? "—",
                systemImage: viewModel.applicationName == nil ? "mic.fill" : "app.fill"
            )
            metadataCell(
                title: "Window",
                value: "—",
                systemImage: "macwindow"
            )
            metadataCell(
                title: "Duration",
                value: TimeFormatter.format(seconds: Float(session.duration)),
                systemImage: "clock"
            )
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("Delete Entry", systemImage: "trash")
        }
        .buttonStyle(.bordered)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d, yyyy 'at' HH:mm"
        return formatter.string(from: session.createdAt)
    }

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.finalTranscriptText, forType: .string)
    }

    @ViewBuilder
    private func metadataCell(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func sectionCard(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text(text.isEmpty ? "No transcript available." : text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
