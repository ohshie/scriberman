import AppKit
import SwiftData
import SwiftUI

struct TranscriptDetailView: View {
    let session: any TranscribableSession
    let onReprocess: (() -> Void)?
    let onDelete: () -> Void
    let onOpenStudy: (() -> Void)?
    let onOpenTransformation: ((UUID) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var showingDeleteConfirmation = false
    @State private var editingTitle: String
    @State private var viewModel: TranscriptDetailViewModel
    @FocusState private var titleFocused: Bool

    init(
        session: any TranscribableSession,
        aiProviderService: AIProviderService,
        onReprocess: (() -> Void)?,
        onDelete: @escaping () -> Void,
        onOpenStudy: (() -> Void)?,
        onOpenTransformation: ((UUID) -> Void)?
    ) {
        self.session = session
        self.onReprocess = onReprocess
        self.onDelete = onDelete
        self.onOpenStudy = onOpenStudy
        self.onOpenTransformation = onOpenTransformation
        _editingTitle = State(initialValue: session.title)
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
        .contentShape(Rectangle())
        .onTapGesture {
            if titleFocused {
                titleFocused = false
            }
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
            TextField("Title", text: $editingTitle)
                .textFieldStyle(.plain)
                .font(.largeTitle.weight(.semibold))
                .focused($titleFocused)
                .onSubmit {
                    commitTitle()
                    titleFocused = false
                }
                .onChange(of: titleFocused) { _, focused in
                    if focused == false {
                        commitTitle()
                    }
                }

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
            if latestTransformation == nil {
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
                        }
                    }
                    .disabled(viewModel.canRunTransformation == false)

                    Spacer(minLength: 0)
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
            }

            if let transformationErrorMessage = viewModel.transformationErrorMessage {
                Text(transformationErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if viewModel.isRunningTransformation {
                SkeletonView()
                    .frame(height: 180)
            } else if let latestTransformation {
                AITransformationPreviewCard(transformation: latestTransformation) {
                    guard viewModel.availableTransformations.isEmpty == false else { return }
                    onOpenTransformation?(latestTransformation.id)
                }
            }
        }
    }

    private var latestTransformation: AITransformation? {
        viewModel.availableTransformations.last
    }

    private var metadataGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .leading)
        ], alignment: .leading, spacing: 16) {
            MetadataCell(
                title: "Application",
                value: viewModel.applicationName ?? "—",
                systemImage: viewModel.applicationName == nil ? "mic.fill" : "app.fill"
            )
            MetadataCell(
                title: "Window",
                value: "—",
                systemImage: "macwindow"
            )
            MetadataCell(
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

    private func commitTitle() {
        session.title = editingTitle
        try? modelContext.save()
    }
}
