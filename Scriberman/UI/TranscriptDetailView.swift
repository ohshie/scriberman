import AppKit
import SwiftUI

struct TranscriptDetailView: View {
    let session: any TranscribableSession
    let onReprocess: (() -> Void)?
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false

    private var viewState: TranscriptDetailViewState {
        TranscriptDetailViewState(session: session)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
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
            sectionCard(title: "Transcript", text: viewState.finalTranscriptText)
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
