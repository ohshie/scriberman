import SwiftData
import SwiftUI

struct TranscriptDetailView: View {
    let session: RecordingSession

    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @FocusState private var titleFocused: Bool
    @State private var exportAlertMessage: String?
    private var viewState: TranscriptDetailViewState {
        TranscriptDetailViewState(session: session)
    }

    var body: some View {
        List {
            if segments.isEmpty {
                ContentUnavailableView("No Transcript Segments", systemImage: "text.bubble")
            } else {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    TranscriptSegmentRow(
                        speakerLabel: speakerLabel(for: segment.speakerId),
                        segment: segment
                    )
                }
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Session Title", text: Binding(
                    get: { session.title },
                    set: { session.title = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280, maxWidth: 520)
                .focused($titleFocused)
                .onSubmit {
                    saveTitleIfNeeded()
                }
                .onChange(of: titleFocused) { wasFocused, isFocused in
                    if wasFocused, !isFocused {
                        saveTitleIfNeeded()
                    }
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Export") {
                    Task {
                        await exportTranscript()
                    }
                }
                .disabled(viewState.isExportDisabled)
            }

            ToolbarItem(placement: .secondaryAction) {
                if viewState.showRetranscribingProgress {
                    ProgressView()
                } else if viewState.showRetranscribeButton {
                    Button("Retranscribe") {
                        Task {
                            await retranscribe()
                        }
                    }
                }
            }
        }
        .alert("Transcript Export", isPresented: Binding(
            get: { exportAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    exportAlertMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    private var segments: [TranscriptSegment] {
        viewState.segments
    }

    private var speakersById: [String: TranscriptSpeaker] {
        viewState.speakersById
    }

    private func speakerLabel(for speakerId: String) -> String {
        if let label = speakersById[speakerId]?.label, !label.isEmpty {
            return label
        }
        return "Speaker"
    }

    private func saveTitleIfNeeded() {
        try? modelContext.save()
    }

    private func exportTranscript() async {
        do {
            try await appState.services.transcriptExportService.export(
                session: session,
                transcript: viewState.displayedTranscript
            )
            exportAlertMessage = "Transcript exported successfully."
        } catch TranscriptExportError.exportCancelled {
            exportAlertMessage = nil
        } catch {
            exportAlertMessage = error.localizedDescription
        }
    }

    private func retranscribe() async {
        guard let workspace = appState.workspace else {
            return
        }
        await appState.services.retranscriptionService.retranscribe(
            session: session,
            workspace: workspace,
            context: modelContext
        )
    }
}

struct TranscriptDetailViewState {
    let session: RecordingSession

    var displayedTranscript: Transcript? {
        session.retranscript ?? session.transcript
    }

    var segments: [TranscriptSegment] {
        (displayedTranscript?.segments ?? []).sorted { $0.startTime < $1.startTime }
    }

    var speakersById: [String: TranscriptSpeaker] {
        Dictionary(uniqueKeysWithValues: (displayedTranscript?.speakers ?? []).map { ($0.id, $0) })
    }

    var isDone: Bool {
        if case .done = session.status {
            return true
        }
        return false
    }

    var isRetranscribing: Bool {
        if case .retranscribing = session.status {
            return true
        }
        return false
    }

    var canRetranscribe: Bool {
        session.mixdownURL != nil && isDone
    }

    var showRetranscribeButton: Bool {
        canRetranscribe && !isRetranscribing
    }

    var showRetranscribingProgress: Bool {
        isRetranscribing
    }

    var isExportDisabled: Bool {
        !isDone || isRetranscribing
    }
}
