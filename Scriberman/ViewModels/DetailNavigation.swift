import Foundation

/// A search to open the detail view with: the query typed in the session list, and the block whose
/// match was selected.
///
/// `token` makes two otherwise identical seeds different values. Opening the same match twice — the
/// user clicking the result again — has to move the view again, and a seed that compared equal to
/// the one already applied would do nothing.
struct TranscriptSearchSeed: Equatable {
    let query: String
    let blockID: UUID?
    let token: UUID

    init(query: String, blockID: UUID?, token: UUID = UUID()) {
        self.query = query
        self.blockID = blockID
        self.token = token
    }
}

/// What the detail column shows for the selected session: the session itself (an empty path), or a
/// transformation pushed on top of it. Drives the detail column's navigation stack.
struct DetailNavigation: Equatable {
    enum Destination: Hashable {
        case transformation(UUID)
    }

    var path: [Destination] = []
    /// The search the session view applies on opening, or `nil` to open it as any selection does.
    private(set) var searchSeed: TranscriptSearchSeed?
    /// Which session list item the seed belongs to.
    private var searchSeedItemID: String?

    var isSessionShown: Bool {
        path.isEmpty
    }

    mutating func openTransformation(_ id: UUID) {
        path.append(.transformation(id))
    }

    mutating func back() {
        _ = path.popLast()
    }

    mutating func returnToSession() {
        path.removeAll()
    }

    /// Selecting another session shows its own view. A selection made by opening a search result
    /// keeps the seed it was given just before.
    mutating func selectionChanged(to itemID: String?) {
        path.removeAll()
        guard itemID == nil || itemID != searchSeedItemID else { return }
        searchSeed = nil
        searchSeedItemID = nil
    }

    /// Opens a search result's session with `seed`, or with none for a title-only result. Called
    /// before the selection changes, so that change keeps the seed.
    mutating func openSearchResult(itemID: String, seed: TranscriptSearchSeed?) {
        path.removeAll()
        searchSeed = seed
        searchSeedItemID = seed == nil ? nil : itemID
    }
}
