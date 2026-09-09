import Foundation
import SwiftData

/// A named, coloured label a recording can carry.
///
/// Tags apply to recordings only. `ImportedSession` is a separate model and is deliberately out of
/// scope; see the `recording-tags` change.
@Model
final class RecordingTag {
    @Attribute(.unique) var id: UUID
    var name: String
    /// `RRGGBB`, uppercase, no leading `#`.
    var colorHex: String
    var createdAt: Date
    /// True for the single seeded tag that acts as the lower bound on a recording's tag count.
    ///
    /// Stored rather than derived from the name, so renaming it — which is allowed — cannot detach
    /// it from the rule it enforces.
    var isDefault: Bool

    /// Inverse of `RecordingSession.tags`.
    ///
    /// Declared rather than omitted: without it, deleting a tag left sessions holding an
    /// invalidated reference, and clearing that reference emptied the whole relationship rather
    /// than removing one element. With the inverse declared, SwiftData maintains both sides and the
    /// default `.nullify` rule removes only the deleted tag.
    @Relationship(inverse: \RecordingSession.tags) var recordings: [RecordingSession] = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String,
        createdAt: Date = .now,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.isDefault = isDefault
    }
}

extension RecordingTag {
    /// Name and colour the default tag is seeded with. Both are editable afterwards; only
    /// `isDefault` is load-bearing.
    enum Defaults {
        static let name = "recording"
        /// System blue.
        static let colorHex = "0A84FF"
    }
}
