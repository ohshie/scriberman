import SwiftData
import SwiftUI

struct JobsView: View {
    @Bindable var viewModel: JobsViewModel
    let items: [JobsViewModel.SessionListItem]
    let pendingSession: PendingSession?
    let isNewSessionIdle: Bool
    @Binding var selection: JobsViewModel.SessionListItem?
    let onDiscardPendingSession: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var isShowingTagFilter = false

    private var sections: [JobsViewModel.SessionDateSection] {
        viewModel.groupedSections(for: items)
    }

    var body: some View {
        // The search field and filter control sit outside this branch on purpose. They used to be
        // chips inside `listContent`, so filtering down to nothing replaced them with the empty
        // state and left no way to unfilter.
        VStack(spacing: 0) {
            searchBar

            Group {
                if items.isEmpty && pendingSession == nil {
                    if viewModel.activeSearchQuery != nil {
                        emptyState(title: "No Results", systemImage: "magnifyingglass")
                    } else {
                        emptyState(
                            title: "No Sessions Yet",
                            systemImage: "list.bullet.rectangle",
                            message: "Record or import audio to start building your session history."
                        )
                    }
                } else {
                    sessionList
                }
            }
        }
        .navigationTitle("Jobs")
        .task {
            await viewModel.refresh()
        }
        // Restarts on every keystroke, which is what cancels an in-flight debounce: transcripts are
        // decoded for the query the user stopped on, not for each one they typed through.
        .task(id: viewModel.searchQuery) {
            await viewModel.updateSearchMatches(for: items)
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

    /// The search field, with the tag filter beside it.
    ///
    /// Always present, with or without sessions: it is how the list is searched, so it cannot be
    /// the thing that disappears when the list empties.
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Search", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))

            tagFilterButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Tag filtering, behind a control rather than permanently on screen.
    ///
    /// The icon fills and tints while a filter is active. Without that, a filtered list is
    /// indistinguishable from a short one, and the conclusion a user draws is that recordings are
    /// missing.
    private var tagFilterButton: some View {
        let isFiltering = !viewModel.selectedTagIDs.isEmpty
        return Button {
            isShowingTagFilter = true
        } label: {
            Image(systemName: isFiltering
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .font(.body)
                .foregroundStyle(isFiltering ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Tags")
        .popover(isPresented: $isShowingTagFilter, arrowEdge: .bottom) {
            tagFilterList
        }
    }

    /// The tags at least one recording carries. A lit tag is unlit by clicking it again, and with
    /// none lit the list is unfiltered — so no separate clear control.
    private var tagFilterList: some View {
        let tags = (try? TagService().tagsInUse(in: modelContext)) ?? []
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(tags) { tag in
                let isSelected = viewModel.selectedTagIDs.contains(tag.id)
                Button {
                    viewModel.toggleTagFilter(tag.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color(tagHex: tag.colorHex) : .secondary)
                        Circle()
                            .fill(Color(tagHex: tag.colorHex))
                            .frame(width: 7, height: 7)
                        Text(tag.name)
                            .font(.callout)
                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(minWidth: 160)
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
                            .contextMenu {
                                tagMenu(for: item)
                            }
                    }
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
                onRetry: { viewModel.retry(session: session, context: modelContext) },
                searchSnippet: viewModel.searchMatches[item.id]?.snippet
            )
        case .imported(let session):
            ImportedSessionRow(
                session: session,
                onRetry: { viewModel.retryImported(session: session, context: modelContext) },
                searchSnippet: viewModel.searchMatches[item.id]?.snippet
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
    private func emptyState(title: String, systemImage: String, message: String? = nil) -> some View {
        VStack {
            Spacer()
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: message.map { Text($0) }
            )
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

}
