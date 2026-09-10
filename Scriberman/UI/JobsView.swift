import SwiftData
import SwiftUI

struct JobsView: View {
    @Bindable var viewModel: JobsViewModel
    let items: [JobsViewModel.SessionListItem]
    let pendingSession: PendingSession?
    /// How many sessions exist before the query and the tag filter narrow them.
    let totalSessionCount: Int
    let isNewSessionIdle: Bool
    @Binding var selection: JobsViewModel.SessionListItem?
    let onDiscardPendingSession: () -> Void
    /// Called when a row is clicked while a search is active, including when that row is already
    /// selected — a selection binding that does not change reports nothing, and clicking a result
    /// again still has to move the view to its match.
    var onOpenSearchResult: (JobsViewModel.SessionListItem) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingTagFilter = false

    /// The one moment the list animates.
    ///
    /// It was three. Rows leaving under a query and the selection moving are both drawn by AppKit —
    /// `List` is an `NSTableView`, and its selection fill is the table's, not ours. A SwiftUI
    /// animation wrapped around that does not animate rows leaving; it animates the whole table
    /// re-rendering, which reads as a wobble on every keystroke and on every click.
    ///
    /// What is left is the container swap: the list being replaced by the empty state, and back.
    /// That is a genuine SwiftUI transition between two views, it is the largest region of the
    /// window, and a cut there reads as the window having been redrawn rather than as a search
    /// having found nothing.
    private var listMotion: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

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
                            .transition(.opacity)
                    } else {
                        emptyState(
                            title: "No Sessions Yet",
                            systemImage: "list.bullet.rectangle",
                            message: "Record or import audio to start building your session history."
                        )
                        .transition(.opacity)
                    }
                } else {
                    sessionList
                        .transition(.opacity)
                }
            }
            // The empty state replaces the largest region of the window; a cut there reads as the
            // window having been redrawn rather than as a search having found nothing.
            .animation(listMotion, value: items.isEmpty)

            listCount
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

    /// What the list holds, under the list.
    ///
    /// Under it rather than in the search row: it summarises what is above it, and the search row
    /// already carries the two controls that cause it to change.
    private var listCount: some View {
        Text(JobsViewModel.listCountText(shown: items.count, total: totalSessionCount))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .overlay(alignment: .top) { Divider() }
    }

    /// The search field, with the tag filter beside it.
    ///
    /// Always present, with or without sessions: it is how the list is searched, so it cannot be
    /// the thing that disappears when the list empties.
    private var searchBar: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)

                TextField("Search", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // One line, fixed. Left to itself the plain field grows to whatever height is going,
            // and the glyph and the text end up on separate lines inside the capsule.
            .frame(height: 22)
            .padding(.horizontal, 8)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))

            tagFilterButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
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
                // A fixed box, so the glyph is not squeezed against the sidebar edge by a search
                // field that would otherwise take every point available.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
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
                            // Inert unless a search is running. A tap recogniser attached to a
                            // list row competes with the row's own click-to-select, so it is masked
                            // off entirely when there is no result to open.
                            .simultaneousGesture(
                                TapGesture().onEnded { onOpenSearchResult(item) },
                                including: viewModel.activeSearchQuery != nil ? .all : .none
                            )
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
