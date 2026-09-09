import SwiftData
import SwiftUI

struct JobsView: View {
    var viewModel: JobsViewModel
    let items: [JobsViewModel.SessionListItem]
    let pendingSession: PendingSession?
    let isNewSessionIdle: Bool
    @Binding var selection: JobsViewModel.SessionListItem?
    let onDiscardPendingSession: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showClearAllConfirmation = false

    private var sections: [JobsViewModel.SessionDateSection] {
        viewModel.groupedSections(for: items)
    }

    var body: some View {
        // The chips sit outside this branch on purpose. They used to live inside `listContent`,
        // so filtering down to nothing replaced them with the empty state and left no way to
        // unfilter.
        VStack(spacing: 0) {
            tagFilterChips

            Group {
                if items.isEmpty && pendingSession == nil {
                    emptyState(
                        title: "No Sessions Yet",
                        systemImage: "list.bullet.rectangle",
                        message: "Record or import audio to start building your session history."
                    )
                } else {
                    sessionList
                }
            }
        }
        .navigationTitle("Jobs")
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
                pendingSession: pendingSession,
                newSelection: newSelection,
                isNewSessionIdle: isNewSessionIdle
            ) else {
                return
            }

            onDiscardPendingSession()
        }
    }

    /// Tag chips above the list. The chips are the tag names themselves; a lit chip is unlit by
    /// clicking it again, and with none lit the list is unfiltered — so no separate clear control.
    @ViewBuilder
    private var tagFilterChips: some View {
        let tags = (try? TagService().tagsInUse(in: modelContext)) ?? []
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags) { tag in
                        let isSelected = viewModel.selectedTagIDs.contains(tag.id)
                        Button {
                            viewModel.toggleTagFilter(tag.id)
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(tagHex: tag.colorHex))
                                    .frame(width: 7, height: 7)
                                Text(tag.name)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? Color(tagHex: tag.colorHex).opacity(0.25)
                                        : Color.secondary.opacity(0.12)
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    isSelected ? Color(tagHex: tag.colorHex) : .clear,
                                    lineWidth: 1
                                )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private var sessionList: some View {
        List(selection: $selection) {
            if let pendingSession {
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
                            .contextMenu {
                                tagMenu(for: item)
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

    /// Tag assignment on right-click.
    ///
    /// Only recordings carry tags, so pending and imported rows produce nothing — an empty
    /// `contextMenu` shows no menu at all, which is the wanted behaviour for those rows.
    @ViewBuilder
    private func tagMenu(for item: JobsViewModel.SessionListItem) -> some View {
        if case .recording(let session) = item {
            TagAssignmentMenuContent(session: session)
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
}
