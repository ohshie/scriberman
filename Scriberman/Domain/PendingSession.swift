import Foundation

struct PendingSession: Identifiable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }
}
