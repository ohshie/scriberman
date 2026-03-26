import SwiftUI
import SwiftData

struct JobsView: View {
    @ObservedObject var viewModel: JobsViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView("No Recordings", systemImage: "list.bullet.rectangle")
                } else {
                    List {
                        ForEach(sessions) { session in
                            RecordingSessionRow(
                                session: session,
                                onTranscribe: { viewModel.transcribe(session: session, context: modelContext) },
                                onRetry: { viewModel.retry(session: session, context: modelContext) },
                                onOpen: { navigationPath.append(session.id) }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.delete(session: session, context: modelContext)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Jobs")
            .navigationDestination(for: UUID.self) { sessionID in
                if let session = sessions.first(where: { $0.id == sessionID }) {
                    TranscriptDetailView(session: session)
                } else {
                    ContentUnavailableView("Recording Not Found", systemImage: "exclamationmark.triangle")
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
    }
}
