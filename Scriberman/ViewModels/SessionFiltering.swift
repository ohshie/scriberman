import Foundation

/// Search and tag filtering over sessions, shared by the window's list and the extension API.
/// Pure: callers pass their own query and tags, so one caller can't change what another sees.
enum SessionFiltering {
    /// The query with its surrounding whitespace removed, or `nil` when there is nothing to search
    /// for, so "    " and "" behave identically.
    static func activeQuery(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The items carrying any of `tagIDs` whose title or transcript contains `query`, in their
    /// original order.
    ///
    /// Tags narrow first and the query searches within them, so the two combine with AND. Several
    /// tags combine as a union: intersecting tags over a personal archive returns almost nothing.
    /// A query that matches nothing yields an empty list, never everything. While tags are given,
    /// imported and pending sessions drop out: they carry no tags, so they can't match. A pending
    /// session also drops out while a query is active: it has no transcript and no title of its
    /// own yet.
    static func filter(
        _ items: [JobsViewModel.SessionListItem],
        query: String?,
        tagIDs: Set<UUID>
    ) -> [JobsViewModel.SessionListItem] {
        var result = items
        if !tagIDs.isEmpty {
            result = result.filter { item in
                guard case .recording(let session) = item else { return false }
                return session.tags.contains { tagIDs.contains($0.id) }
            }
        }
        if let query = query.flatMap(activeQuery) {
            result = result.filter { matches(query: query, item: $0) != nil }
        }
        return result
    }

    /// How an item matched a query, or `nil` when it did not.
    ///
    /// A session can match on both; the transcript wins, because that is the match a snippet can be
    /// built from. Matching is `localizedStandardContains`, which is case- and diacritic-insensitive,
    /// the same comparison the in-transcript find bar uses.
    static func matches(query: String, item: JobsViewModel.SessionListItem) -> JobsViewModel.SessionSearchMatchKind? {
        switch item {
        case .pending:
            return nil
        case .recording(let session):
            return matches(query: query, title: session.title, searchableText: session.searchableText)
        case .imported(let session):
            return matches(query: query, title: session.title, searchableText: session.searchableText)
        }
    }

    private static func matches(
        query: String,
        title: String,
        searchableText: String?
    ) -> JobsViewModel.SessionSearchMatchKind? {
        if searchableText?.localizedStandardContains(query) == true {
            return .transcript
        }
        if title.localizedStandardContains(query) {
            return .title
        }
        return nil
    }
}
