import SwiftUI
import SwiftData

struct JobsView: View {
    @ObservedObject var viewModel: JobsViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var sessions: [RecordingSession]

    var body: some View {
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
                            onOpen: {}
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
        .task {
            await viewModel.refresh()
        }
        .navigationTitle("Jobs")
    }
}
