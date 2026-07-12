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

                transformMenu

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete Entry", systemImage: "trash")
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

            Text(headerFactsLine)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    private var headerFactsLine: String {
        var facts = [formattedDate, viewModel.durationText, viewModel.sourcesText]
        if viewModel.wordCount > 0 {
            facts.append("\(viewModel.wordCount) words")
        }
        return facts.joined(separator: " · ")
    }

    private var transformMenu: some View {
        Menu {
            if viewModel.prompts.isEmpty {
                Button("Add prompts in Settings") {}
                    .disabled(true)
            } else {
                if viewModel.shouldWarnAboutTranscriptLength {
                    Section {
                        Label("Long transcript — the model may hit context limits", systemImage: "exclamationmark.triangle")
                    }
                }
                ForEach(viewModel.prompts) { prompt in
                    Button(prompt.name) {
                        viewModel.selectedPromptID = prompt.id
                        Task {
                            await viewModel.runTransformation()
                        }
                    }
                }
            }
        } label: {
            Label("Transform", systemImage: "sparkles")
        }
        .disabled(viewModel.isRunningTransformation || viewModel.finalTranscriptText.isEmpty)
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
            if let transformationErrorMessage = viewModel.transformationErrorMessage {
                Text(transformationErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if viewModel.isRunningTransformation {
                SkeletonView()
                    .frame(height: 180)
            } else if let latestTransformation {
                AITransformationPreviewCard(
                    transformation: latestTransformation,
                    onTap: {
                        guard viewModel.availableTransformations.isEmpty == false else { return }
                        onOpenTransformation?(latestTransformation.id)
                    },
                    onCopy: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(latestTransformation.resultText, forType: .string)
                    }
                )
            }
        }
    }

    private var latestTransformation: AITransformation? {
        viewModel.availableTransformations.last
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
