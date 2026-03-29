import SwiftData
import SwiftUI

struct JobsView: View {
    @ObservedObject var viewModel: JobsViewModel
    let items: [JobsViewModel.SessionListItem]
    @Binding var selection: JobsViewModel.SessionListItem?

    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var showClearAllConfirmation = false

    private var sections: [JobsViewModel.SessionDateSection] {
        viewModel.groupedSections(for: items)
    }

    var body: some View {
        Group {
            if items.isEmpty && appState.pendingSession == nil {
                emptyState(
                    title: "No Sessions Yet",
                    systemImage: "list.bullet.rectangle",
                    message: "Record or import audio to start building your session history."
                )
            } else {
                listContent
            }
        }
        .navigationTitle("Jobs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.selectPendingSession()
                    if let pendingSession = appState.pendingSession {
                        selection = .pending(pendingSession)
                    }
                } label: {
                    Label("New Session", systemImage: "plus")
                }
            }
        }
        .confirmationDialog(
            "Clear All Sessions",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                clearAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes every session from the workspace.")
        }
        .task {
            await viewModel.refresh()
        }
        .onChange(of: selection) { _, newSelection in
            guard viewModel.shouldDiscardPendingSessionOnSelectionChange(
                pendingSession: appState.pendingSession,
                newSelection: newSelection,
                isNewSessionIdle: isNewSessionIdle
            ) else {
                return
            }

            appState.discardPendingSession()
        }
    }

    private var listContent: some View {
        List(selection: $selection) {
            if let pendingSession = appState.pendingSession {
                row(for: .pending(pendingSession))
                    .tag(JobsViewModel.SessionListItem.pending(pendingSession))
            }

            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        row(for: item)
                            .tag(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                deleteButton(for: item)
                            }
                    }
                }
            }

            if !items.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearAllConfirmation = true
                    } label: {
                        Label("Clear All", systemImage: "trash")
                    }
                    .disabled(items.isEmpty)
                } footer: {
                    Text("Deletes every session after confirmation.")
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(for item: JobsViewModel.SessionListItem) -> some View {
        switch item {
        case .pending(let session):
            Text(session.title)
        case .recording(let session):
            RecordingSessionRow(
                session: session,
                onTranscribe: { viewModel.transcribe(session: session, context: modelContext) },
                onRetry: { viewModel.retry(session: session, context: modelContext) }
            )
        case .imported(let session):
            ImportedSessionRow(
                session: session,
                onRetry: { viewModel.retryImported(session: session, context: modelContext) }
            )
        }
    }

    @ViewBuilder
    private func deleteButton(for item: JobsViewModel.SessionListItem) -> some View {
        switch item {
        case .pending:
            EmptyView()
        case .recording(let session):
            Button(role: .destructive) {
                viewModel.delete(session: session, context: modelContext)
                if selection == item {
                    selection = nil
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        case .imported(let session):
            Button(role: .destructive) {
                viewModel.deleteImported(session: session, context: modelContext)
                if selection == item {
                    selection = nil
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func emptyState(title: String, systemImage: String, message: String) -> some View {
        VStack {
            Spacer()
            ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private func clearAll() {
        for item in items {
            switch item {
            case .pending:
                continue
            case .recording(let session):
                viewModel.delete(session: session, context: modelContext)
            case .imported(let session):
                viewModel.deleteImported(session: session, context: modelContext)
            }
        }
        selection = nil
    }

    private var isNewSessionIdle: Bool {
        if case .idle = appState.newSessionViewModel.state {
            return true
        }

        return false
    }
}
