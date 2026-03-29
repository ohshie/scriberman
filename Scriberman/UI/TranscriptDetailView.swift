import AppKit
import SwiftUI

struct TranscriptDetailView: View {
    let session: any TranscribableSession
    let onReprocess: (() -> Void)?
    let onDelete: () -> Void

    @Environment(AIProviderService.self) private var aiProviderService
    @State private var showingDeleteConfirmation = false
    @State private var promptStore = AIPromptStore()
    @State private var prompts: [AIPrompt] = []
    @State private var selectedPromptID: UUID?
    @State private var selectedTransformationID: UUID?
    @State private var isRunningTransformation = false
    @State private var transformationErrorMessage: String?
    @State private var showingStudyTranscript = false

    private var viewState: TranscriptDetailViewState {
        TranscriptDetailViewState(session: session)
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
                        if viewState.isReprocessing {
                            Label("Reprocessing", systemImage: "hourglass")
                        } else {
                            Label("Reprocess", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(!viewState.canReprocess)
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
        .sheet(isPresented: $showingStudyTranscript) {
            if let transcript = viewState.displayedTranscript {
                TranscriptStudyView(session: session, transcript: transcript)
                    .frame(minWidth: 720, minHeight: 520)
            } else {
                EmptyView()
            }
        }
        .task {
            loadPromptState()
            refreshSelectedTransformation()
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
            TranscriptPreviewView(blocks: transcriptBlocks)

            Button {
                showingStudyTranscript = true
            } label: {
                Label("Study Transcript", systemImage: "book.pages")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewState.displayedTranscript == nil)
        }
    }

    private var transcriptBlocks: [TranscriptBlock] {
        guard let transcript = viewState.displayedTranscript else { return [] }
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
                Picker("Prompt", selection: $selectedPromptID) {
                    ForEach(prompts) { prompt in
                        Text(prompt.name).tag(Optional(prompt.id))
                    }
                }
                .disabled(prompts.isEmpty || isRunningTransformation)
                .frame(maxWidth: 320)

                Button(runButtonTitle) {
                    runTransformation()
                }
                .disabled(canRunTransformation == false)
            }

            if prompts.isEmpty {
                Text("Add prompts in Settings to enable transformations.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if shouldWarnAboutTranscriptLength {
                Text("Transcript is longer than 40,000 characters. The model may fail due to context limits.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            if viewState.availableTransformations.isEmpty == false {
                Picker("History", selection: $selectedTransformationID) {
                    ForEach(viewState.availableTransformations) { transformation in
                        Text(transformation.historyLabel).tag(Optional(transformation.id))
                    }
                }
                .disabled(isRunningTransformation)
            }

            if let transformationErrorMessage {
                Text(transformationErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if isRunningTransformation {
                SkeletonView()
                    .frame(height: 180)
            } else if let selectedTransformation = selectedTransformation {
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
                value: viewState.applicationName ?? "—",
                systemImage: viewState.applicationName == nil ? "mic.fill" : "app.fill"
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
        pasteboard.setString(viewState.finalTranscriptText, forType: .string)
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

    private var selectedTransformation: AITransformation? {
        let history = viewState.availableTransformations
        if let selectedTransformationID, let selected = history.first(where: { $0.id == selectedTransformationID }) {
            return selected
        }
        return history.last
    }

    private var runButtonTitle: String {
        viewState.availableTransformations.isEmpty ? "Run" : "Rerun"
    }

    private var shouldWarnAboutTranscriptLength: Bool {
        aiProviderService.shouldWarnAboutTranscriptLength(viewState.finalTranscriptText)
    }

    private var canRunTransformation: Bool {
        prompts.isEmpty == false &&
        selectedPrompt != nil &&
        isRunningTransformation == false &&
        viewState.finalTranscriptText.isEmpty == false
    }

    private var selectedPrompt: AIPrompt? {
        guard let selectedPromptID else { return nil }
        return prompts.first { $0.id == selectedPromptID }
    }

    private func loadPromptState() {
        prompts = promptStore.loadPrompts().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if let lastUsedPromptID = promptStore.loadLastUsedPromptID(),
           prompts.contains(where: { $0.id == lastUsedPromptID }) {
            selectedPromptID = lastUsedPromptID
        } else if selectedPromptID == nil {
            selectedPromptID = prompts.first?.id
        }
    }

    private func refreshSelectedTransformation() {
        let history = viewState.availableTransformations
        if history.isEmpty {
            selectedTransformationID = nil
            return
        }
        if let selectedTransformationID, history.contains(where: { $0.id == selectedTransformationID }) {
            return
        }
        selectedTransformationID = history.last?.id
    }

    private func runTransformation() {
        guard let selectedPrompt else { return }

        transformationErrorMessage = nil
        isRunningTransformation = true

        Task {
            do {
                let resultText = try await aiProviderService.performTransformation(
                    transcript: viewState.finalTranscriptText,
                    systemPrompt: selectedPrompt.content
                )

                let transformation = AITransformation(
                    promptName: selectedPrompt.name,
                    modelID: aiProviderService.selectedModelID ?? "unknown",
                    resultText: resultText
                )
                var history = session.aiTransformations
                history.append(transformation)
                session.aiTransformations = history
                selectedTransformationID = transformation.id
                promptStore.setLastUsedPromptID(selectedPrompt.id)
            } catch {
                transformationErrorMessage = error.localizedDescription
            }

            isRunningTransformation = false
        }
    }
}

struct TranscriptDetailViewState {
    let session: any TranscribableSession

    var finalTranscriptText: String {
        displayedTranscript?.fullText ?? ""
    }

    var originalTranscriptText: String? {
        session.transcript?.fullText
    }

    var applicationName: String? {
        if let recordingSession = session as? RecordingSession {
            return recordingSession.capturedAppName
        }
        return nil
    }

    var displayedTranscript: Transcript? {
        session.retranscript ?? session.transcript
    }

    var availableTransformations: [AITransformation] {
        session.aiTransformations.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var isReprocessed: Bool {
        session.retranscript != nil
    }

    var canReprocess: Bool {
        guard session.mixdownURL != nil else { return false }
        switch session.status {
        case .converting, .transcribing, .retranscribing:
            return false
        case .recorded, .done, .error:
            return true
        }
    }

    var isReprocessing: Bool {
        session.status == .retranscribing
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
