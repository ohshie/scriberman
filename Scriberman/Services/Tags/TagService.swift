import Foundation
import OSLog
import SwiftData

/// Owns every transition that can change a recording's tags.
///
/// The bounds — at least one tag, at most three — cannot be expressed in SwiftData, so they are
/// invariants of this type instead. There are four places they can break, and only the first is
/// obvious: assigning, unassigning, deleting a tag that recordings carry, and backfilling
/// recordings that predate tags. All four live here so none of them can drift apart.
///
/// The default tag is a placeholder, not a member: it is applied when a recording has nothing,
/// displaced by the first real tag, and restored when the last real tag goes. It is therefore never
/// alongside another tag, which is what lets its filter chip mean "untagged" and leaves all three
/// slots to the user.
struct TagService {
    /// Most tags a recording may carry.
    static let maximumTagsPerRecording = 3

    private let logger = Logger(subsystem: "Scriberman", category: "TagService")
    /// Injected so tests get deterministic colours.
    private let randomColorHex: @Sendable () -> String

    init(randomColorHex: (@Sendable () -> String)? = nil) {
        self.randomColorHex = randomColorHex ?? { TagColor.randomUsableHex() }
    }

    // MARK: - Seeding

    /// Returns the default tag, creating it if it does not exist.
    ///
    /// Idempotent, and deliberately not tied to Settings being opened: recording creation applies
    /// the default tag, so it has to exist before the first recording can start.
    @discardableResult
    func seedDefaultTagIfNeeded(in context: ModelContext) throws -> RecordingTag {
        if let existing = try defaultTag(in: context) {
            return existing
        }
        let tag = RecordingTag(
            name: RecordingTag.Defaults.name,
            colorHex: RecordingTag.Defaults.colorHex,
            isDefault: true
        )
        context.insert(tag)
        try context.save()
        logger.notice("Seeded the default tag.")
        return tag
    }

    func defaultTag(in context: ModelContext) throws -> RecordingTag? {
        let descriptor = FetchDescriptor<RecordingTag>(predicate: #Predicate { $0.isDefault })
        return try context.fetch(descriptor).first
    }

    /// Every tag a user may assign — that is, all of them except the default, which is applied and
    /// removed automatically and is never offered.
    func assignableTags(in context: ModelContext) throws -> [RecordingTag] {
        let descriptor = FetchDescriptor<RecordingTag>(
            predicate: #Predicate { !$0.isDefault },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try context.fetch(descriptor)
    }

    // MARK: - Creating and editing

    /// Creates a tag with a random usable colour.
    ///
    /// - Throws: `TagError.emptyName` when `name` has no non-whitespace content.
    @discardableResult
    func createTag(name: String, in context: ModelContext) throws -> RecordingTag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        // Duplicate names are allowed; colour distinguishes them.
        let tag = RecordingTag(name: trimmed, colorHex: randomColorHex())
        context.insert(tag)
        try context.save()
        return tag
    }

    func rename(_ tag: RecordingTag, to name: String, in context: ModelContext) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TagError.emptyName }
        tag.name = trimmed
        try context.save()
    }

    func recolor(_ tag: RecordingTag, to colorHex: String, in context: ModelContext) throws {
        tag.colorHex = TagColor.normalizedHex(colorHex)
        try context.save()
    }

    // MARK: - Assignment

    /// Applies `tag` to `session`.
    ///
    /// Refuses a fourth tag rather than evicting one: silent eviction discards a choice the user
    /// made without telling them. The default tag is displaced here, which is the only way it ever
    /// leaves a recording that still has tags.
    @discardableResult
    func assign(_ tag: RecordingTag, to session: RecordingSession, in context: ModelContext) throws -> Bool {
        guard !tag.isDefault else {
            // The default tag is applied by the rules below, never chosen.
            return false
        }
        guard !session.tags.contains(where: { $0.id == tag.id }) else { return true }

        let realTags = session.tags.filter { !$0.isDefault }
        guard realTags.count < Self.maximumTagsPerRecording else {
            return false
        }

        session.tags = realTags + [tag]
        try context.save()
        return true
    }

    /// Removes `tag` from `session`, restoring the default when nothing is left.
    func unassign(_ tag: RecordingTag, from session: RecordingSession, in context: ModelContext) throws {
        session.tags.removeAll { $0.id == tag.id }
        try restoreFloorIfNeeded(for: session, in: context)
        try context.save()
    }

    // MARK: - Deletion

    /// Deletes `tag` and removes it from every recording carrying it, restoring the floor on any
    /// recording the removal would leave empty.
    ///
    /// The sweep and the repair are one operation. Splitting them would leave the bound false for
    /// however long it took something else to notice.
    func delete(_ tag: RecordingTag, in context: ModelContext) throws {
        guard !tag.isDefault else { throw TagError.defaultTagNotDeletable }

        let tagID = tag.id
        // Filtered in memory rather than by `#Predicate`. A predicate with a nested closure over
        // the to-many relationship does not match here, which leaves sessions holding a reference
        // to a deleted tag — SwiftData then traps on the next access. Correctness over cleverness:
        // deletion is rare and the sweep has to be exhaustive.
        let affected = try context.fetch(FetchDescriptor<RecordingSession>())
            .filter { session in session.tags.contains { $0.id == tagID } }
        for session in affected {
            session.tags.removeAll { $0.id == tagID }
            try restoreFloorIfNeeded(for: session, in: context)
        }
        context.delete(tag)
        try context.save()
        logger.notice("Deleted a tag and removed it from \(affected.count, privacy: .public) recording(s).")
    }

    // MARK: - The floor

    /// Applies the default tag to `session` when it carries nothing.
    ///
    /// Does not save; callers batch this with their own save.
    private func restoreFloorIfNeeded(for session: RecordingSession, in context: ModelContext) throws {
        guard session.tags.isEmpty else { return }
        session.tags = [try seedDefaultTagIfNeeded(in: context)]
    }

    /// Applies the default tag to a session being created.
    func applyDefaultTag(to session: RecordingSession, in context: ModelContext) throws {
        session.tags = [try seedDefaultTagIfNeeded(in: context)]
    }

    // MARK: - Backfill

    /// Brings every recording carrying no tags to the default tag.
    ///
    /// Eager rather than repaired on read: repairing lazily would leave the bound false for every
    /// recording nobody had displayed yet, which is exactly the "true except where nobody looked"
    /// property this codebase has spent two changes removing.
    ///
    /// - Returns: how many recordings were changed.
    @discardableResult
    func backfillUntaggedRecordings(in context: ModelContext) throws -> Int {
        let defaultTag = try seedDefaultTagIfNeeded(in: context)
        // In memory for the same reason as the deletion sweep above.
        let untagged = try context.fetch(FetchDescriptor<RecordingSession>())
            .filter { $0.tags.isEmpty }
        guard !untagged.isEmpty else { return 0 }
        for session in untagged {
            session.tags = [defaultTag]
        }
        try context.save()
        logger.notice("Backfilled \(untagged.count, privacy: .public) untagged recording(s) to the default tag.")
        return untagged.count
    }
}

enum TagError: LocalizedError, Equatable {
    case emptyName
    case defaultTagNotDeletable

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "A tag needs a name."
        case .defaultTagNotDeletable:
            return "The default tag cannot be deleted."
        }
    }
}

/// Colour generation and hex handling for tags.
enum TagColor {
    /// Saturation and brightness are held in a middle band so a generated colour is neither black,
    /// nor white, nor washed out. Hue is unconstrained.
    ///
    /// No attempt is made to avoid colours close to existing tags: distinctness is the user's
    /// judgement, the colour is editable immediately, and avoidance degrades once several tags
    /// exist.
    static let saturationRange: ClosedRange<Double> = 0.55...0.85
    static let brightnessRange: ClosedRange<Double> = 0.55...0.85

    static func randomUsableHex(
        using generator: inout some RandomNumberGenerator
    ) -> String {
        let hue = Double.random(in: 0..<1, using: &generator)
        let saturation = Double.random(in: saturationRange, using: &generator)
        let brightness = Double.random(in: brightnessRange, using: &generator)
        return hex(fromHue: hue, saturation: saturation, brightness: brightness)
    }

    static func randomUsableHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return randomUsableHex(using: &generator)
    }

    /// HSB to `RRGGBB`.
    static func hex(fromHue hue: Double, saturation: Double, brightness: Double) -> String {
        let sector = (hue - hue.rounded(.down)) * 6
        let index = Int(sector) % 6
        let fractional = sector - Double(index)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fractional)
        let t = brightness * (1 - saturation * (1 - fractional))

        let rgb: (Double, Double, Double)
        switch index {
        case 0: rgb = (brightness, t, p)
        case 1: rgb = (q, brightness, p)
        case 2: rgb = (p, brightness, t)
        case 3: rgb = (p, q, brightness)
        case 4: rgb = (t, p, brightness)
        default: rgb = (brightness, p, q)
        }

        let red = Int((rgb.0 * 255).rounded())
        let green = Int((rgb.1 * 255).rounded())
        let blue = Int((rgb.2 * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }

    /// Uppercased, `#`-stripped. Falls back to the default colour for anything unparseable, so a
    /// bad value cannot leave a tag with no colour at all.
    static func normalizedHex(_ raw: String) -> String {
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()
        guard stripped.count == 6, stripped.allSatisfy(\.isHexDigit) else {
            return RecordingTag.Defaults.colorHex
        }
        return stripped
    }

    /// Red, green and blue in `0...1`, or `nil` when the hex cannot be parsed.
    static func components(fromHex raw: String) -> (red: Double, green: Double, blue: Double)? {
        let hex = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
