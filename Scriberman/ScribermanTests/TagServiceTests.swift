import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Scriberman

/// Covers the two bounds SwiftData cannot express — at least one tag, at most three — at every
/// transition that can break them, and the placeholder behaviour of the default tag.
struct TagServiceTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            SpeakerProfile.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeSession(in context: ModelContext, title: String = "Session") -> RecordingSession {
        let session = RecordingSession(duration: 60, micAudioURL: "/tmp/mic.wav", title: title)
        context.insert(session)
        return session
    }

    private var service: TagService { TagService(randomColorHex: { "112233" }) }

    // MARK: - Seeding

    @Test
    func testSeedingCreatesTheDefaultTagOnce() throws {
        let context = try makeContext()
        let service = service

        let first = try service.seedDefaultTagIfNeeded(in: context)
        let second = try service.seedDefaultTagIfNeeded(in: context)

        #expect(first.id == second.id)
        #expect(first.isDefault)
        #expect(first.name == RecordingTag.Defaults.name)
        #expect(try context.fetch(FetchDescriptor<RecordingTag>()).count == 1)
    }

    @Test
    func testTheDefaultTagIsNotAssignable() throws {
        let context = try makeContext()
        let service = service
        _ = try service.seedDefaultTagIfNeeded(in: context)
        _ = try service.createTag(name: "Work", in: context)

        let assignable = try service.assignableTags(in: context)

        // The default is applied and removed by rule, never chosen, so offering it would allow a
        // state the bounds have no rule for.
        #expect(assignable.count == 1)
        #expect(assignable.first?.name == "Work")
    }

    // MARK: - Creating

    @Test
    func testATagCannotBeCreatedWithoutAName() throws {
        let context = try makeContext()
        #expect(throws: TagError.emptyName) {
            try service.createTag(name: "   ", in: context)
        }
        #expect(try context.fetch(FetchDescriptor<RecordingTag>()).isEmpty)
    }

    @Test
    func testRenamingToAnEmptyNameIsRefused() throws {
        let context = try makeContext()
        let service = service
        let tag = try service.createTag(name: "Work", in: context)

        #expect(throws: TagError.emptyName) {
            try service.rename(tag, to: "", in: context)
        }
        #expect(tag.name == "Work")
    }

    @Test
    func testDuplicateNamesAreAllowed() throws {
        let context = try makeContext()
        let service = service
        _ = try service.createTag(name: "Work", in: context)
        _ = try service.createTag(name: "Work", in: context)

        // Distinguished by colour, not name.
        #expect(try context.fetch(FetchDescriptor<RecordingTag>()).count == 2)
    }

    // MARK: - The placeholder rule

    @Test
    func testTheFirstRealTagDisplacesTheDefault() throws {
        let context = try makeContext()
        let service = service
        let session = makeSession(in: context)
        try service.applyDefaultTag(to: session, in: context)
        #expect(session.tags.count == 1)
        #expect(session.tags.first?.isDefault == true)

        let work = try service.createTag(name: "Work", in: context)
        _ = try service.assign(work, to: session, in: context)

        #expect(session.tags.count == 1)
        #expect(session.tags.first?.id == work.id)
        #expect(!session.tags.contains { $0.isDefault })
    }

    @Test
    func testRemovingTheLastRealTagRestoresTheDefault() throws {
        let context = try makeContext()
        let service = service
        let session = makeSession(in: context)
        try service.applyDefaultTag(to: session, in: context)
        let work = try service.createTag(name: "Work", in: context)
        _ = try service.assign(work, to: session, in: context)

        try service.unassign(work, from: session, in: context)

        #expect(session.tags.count == 1)
        #expect(session.tags.first?.isDefault == true)
    }

    @Test
    func testTheDefaultIsNeverAlongsideAnotherTag() throws {
        let context = try makeContext()
        let service = service
        let session = makeSession(in: context)
        try service.applyDefaultTag(to: session, in: context)
        let work = try service.createTag(name: "Work", in: context)
        let client = try service.createTag(name: "Client", in: context)

        _ = try service.assign(work, to: session, in: context)
        _ = try service.assign(client, to: session, in: context)

        #expect(session.tags.count == 2)
        #expect(!session.tags.contains { $0.isDefault })
    }

    @Test
    func testAssigningTheDefaultDirectlyDoesNothing() throws {
        let context = try makeContext()
        let service = service
        let session = makeSession(in: context)
        let defaultTag = try service.seedDefaultTagIfNeeded(in: context)
        let work = try service.createTag(name: "Work", in: context)
        _ = try service.assign(work, to: session, in: context)

        let applied = try service.assign(defaultTag, to: session, in: context)

        #expect(!applied)
        #expect(session.tags.count == 1)
        #expect(session.tags.first?.id == work.id)
    }

    // MARK: - The upper bound

    @Test
    func testAFourthTagIsRefusedWithoutEvictingAnything() throws {
        let context = try makeContext()
        let service = service
        let session = makeSession(in: context)
        try service.applyDefaultTag(to: session, in: context)
        let tags = try (1...4).map { try service.createTag(name: "RecordingTag \($0)", in: context) }

        for tag in tags.prefix(3) {
            #expect(try service.assign(tag, to: session, in: context))
        }
        let fourth = try service.assign(tags[3], to: session, in: context)

        #expect(!fourth)
        #expect(session.tags.count == 3)
        // Silent eviction would discard a choice the user made without telling them.
        #expect(Set(session.tags.map(\.id)) == Set(tags.prefix(3).map(\.id)))
    }

    @Test
    func testAssigningATagTwiceIsANoOp() throws {
        let context = try makeContext()
        let service = service
        let session = makeSession(in: context)
        try service.applyDefaultTag(to: session, in: context)
        let work = try service.createTag(name: "Work", in: context)

        _ = try service.assign(work, to: session, in: context)
        _ = try service.assign(work, to: session, in: context)

        #expect(session.tags.count == 1)
    }

    // MARK: - Deletion

    @Test
    func testDeletingATagRemovesItFromEveryRecording() throws {
        let context = try makeContext()
        let service = service
        let work = try service.createTag(name: "Work", in: context)
        let client = try service.createTag(name: "Client", in: context)
        let sessions = try (1...3).map { index -> RecordingSession in
            let session = makeSession(in: context, title: "S\(index)")
            try service.applyDefaultTag(to: session, in: context)
            _ = try service.assign(work, to: session, in: context)
            _ = try service.assign(client, to: session, in: context)
            return session
        }
        try context.save()

        try service.delete(work, in: context)

        for session in sessions {
            #expect(!session.tags.contains { $0.name == "Work" })
            #expect(session.tags.count == 1)
        }
        #expect(try context.fetch(FetchDescriptor<RecordingTag>()).allSatisfy { $0.name != "Work" })
    }

    @Test
    func testDeletionRestoresTheFloorOnStrandedRecordings() throws {
        let context = try makeContext()
        let service = service
        let work = try service.createTag(name: "Work", in: context)
        let session = makeSession(in: context)
        try service.applyDefaultTag(to: session, in: context)
        _ = try service.assign(work, to: session, in: context)
        try context.save()
        #expect(session.tags.count == 1)

        try service.delete(work, in: context)

        // Removing its only tag would strand it at zero; the sweep and the repair are one step.
        #expect(session.tags.count == 1)
        #expect(session.tags.first?.isDefault == true)
    }

    @Test
    func testTheDefaultTagCannotBeDeleted() throws {
        let context = try makeContext()
        let service = service
        let defaultTag = try service.seedDefaultTagIfNeeded(in: context)

        #expect(throws: TagError.defaultTagNotDeletable) {
            try service.delete(defaultTag, in: context)
        }
        #expect(try context.fetch(FetchDescriptor<RecordingTag>()).count == 1)
    }

    // MARK: - Backfill

    @Test
    func testBackfillAppliesTheDefaultToUntaggedRecordingsOnly() throws {
        let context = try makeContext()
        let service = service
        let work = try service.createTag(name: "Work", in: context)
        let untagged = (1...3).map { makeSession(in: context, title: "Untagged \($0)") }
        let tagged = makeSession(in: context, title: "Tagged")
        try service.applyDefaultTag(to: tagged, in: context)
        _ = try service.assign(work, to: tagged, in: context)
        try context.save()

        let changed = try service.backfillUntaggedRecordings(in: context)

        #expect(changed == 3)
        for session in untagged {
            #expect(session.tags.count == 1)
            #expect(session.tags.first?.isDefault == true)
        }
        #expect(tagged.tags.map(\.id) == [work.id])
    }

    @Test
    func testASecondBackfillChangesNothing() throws {
        let context = try makeContext()
        let service = service
        _ = makeSession(in: context)
        try context.save()

        #expect(try service.backfillUntaggedRecordings(in: context) == 1)
        #expect(try service.backfillUntaggedRecordings(in: context) == 0)
    }

    // MARK: - Scene wiring

    /// Settings is its own scene and does not inherit the WindowGroup's model container. Without an
    /// explicit one, every `@Query` and `@Environment(\.modelContext)` inside Settings resolves to a
    /// throwaway context — reads return nothing and writes go nowhere, so tag management silently
    /// does nothing.
    @Test
    func testTheSettingsSceneAttachesTheModelContainer() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let app = try String(
            contentsOf: testsDirectory.appendingPathComponent("../ScribermanApp.swift"),
            encoding: .utf8
        )
        let settingsRange = try #require(app.range(of: "Settings {"))
        let afterSettings = app[settingsRange.upperBound...]
        #expect(afterSettings.contains(".modelContainer(modelContainer)"))
    }

    @Test
    func testTagFailuresAreLoggedRatherThanSwallowed() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for file in ["../UI/TagSettingsView.swift", "../UI/TagAssignmentMenu.swift"] {
            let source = try String(
                contentsOf: testsDirectory.appendingPathComponent(file),
                encoding: .utf8
            )
            // `try?` hid the reason nothing happened; every failure path logs now.
            #expect(!source.contains("try? service."))
            #expect(source.contains("logger.error"))
        }
    }

    // MARK: - Settings surface

    private func tagSettingsSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TagSettingsView.swift"),
            encoding: .utf8
        )
    }

    @Test
    func testSettingsOffersTagManagement() throws {
        let source = try tagSettingsSource()
        #expect(source.contains("Add new tag"))
        #expect(source.contains("TextField("))
        #expect(source.contains("ColorPicker("))
    }

    @Test
    func testTheDefaultTagHasNoDeleteAction() throws {
        let source = try tagSettingsSource()
        #expect(source.contains("if !tag.isDefault"))
    }

    @Test
    func testDeletionIsConfirmedBeforeAnythingIsRemoved() throws {
        let source = try tagSettingsSource()
        #expect(source.contains("confirmationDialog"))
        #expect(source.contains("Are you sure you want to remove"))
        // The delete only runs from the confirming button, never from the trash button directly.
        let trashRange = try #require(source.range(of: "pendingDeletion = tag"))
        let afterTrash = source[trashRange.upperBound...].prefix(120)
        #expect(!afterTrash.contains("service.delete"))
    }

    @Test
    func testSettingsIsWiredIntoTheGeneralTab() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let settings = try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(settings.contains("Section(\"Tags\")"))
        #expect(settings.contains("TagSettingsView()"))
    }

    /// A colour chosen in the picker has to survive the round trip to storage.
    @Test
    func testColorRoundTripsThroughHex() throws {
        for hex in ["0A84FF", "FF0000", "00FF00", "123456"] {
            let color = Color(tagHex: hex)
            #expect(color.tagHexValue == hex)
        }
    }

    // MARK: - On-disk store

    /// The in-memory tests above cannot show that a relationship survives a real store. This adds
    /// a to-many relationship to a model that already exists on disk, which is heavier than the
    /// optional attributes previous changes added.
    @Test
    func testTagsAndBackfillSurviveAnOnDiskStore() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.sqlite")

        func openStore() throws -> ModelContext {
            let container = try ModelContainer(
                for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                SpeakerProfile.self, RecordingTag.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            return ModelContext(container)
        }

        let untaggedIDs = (1...3).map { _ in UUID() }
        let taggedID = UUID()

        // Recordings written before tags existed carry none.
        do {
            let context = try openStore()
            for id in untaggedIDs {
                context.insert(
                    RecordingSession(id: id, duration: 60, micAudioURL: "/tmp/a.wav", title: "Old")
                )
            }
            context.insert(
                RecordingSession(id: taggedID, duration: 60, micAudioURL: "/tmp/b.wav", title: "Newer")
            )
            try context.save()
        }

        // Seed and backfill, as the app does at startup.
        do {
            let context = try openStore()
            let service = TagService()
            let work = try service.createTag(name: "Work", in: context)
            let tagged = try #require(
                try context.fetch(FetchDescriptor<RecordingSession>())
                    .first { $0.id == taggedID }
            )
            try service.applyDefaultTag(to: tagged, in: context)
            _ = try service.assign(work, to: tagged, in: context)
            try context.save()

            #expect(try service.backfillUntaggedRecordings(in: context) == 3)
        }

        // Reopen: the relationship and the backfill both survived.
        do {
            let context = try openStore()
            let sessions = try context.fetch(FetchDescriptor<RecordingSession>())
            #expect(sessions.count == 4)
            #expect(sessions.allSatisfy { !$0.tags.isEmpty })

            for id in untaggedIDs {
                let session = try #require(sessions.first { $0.id == id })
                #expect(session.tags.count == 1)
                #expect(session.tags.first?.isDefault == true)
            }
            let tagged = try #require(sessions.first { $0.id == taggedID })
            #expect(tagged.tags.map(\.name) == ["Work"])

            // A second run over a store that is already correct changes nothing.
            #expect(try TagService().backfillUntaggedRecordings(in: context) == 0)
        }
    }

    /// Deleting a tag on a real store must leave both sides of the relationship consistent — this
    /// is the case that failed before the inverse was declared.
    @Test
    func testDeletingATagOnAnOnDiskStoreLeavesTheRelationshipConsistent() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.sqlite")

        func openStore() throws -> ModelContext {
            let container = try ModelContainer(
                for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                SpeakerProfile.self, RecordingTag.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            return ModelContext(container)
        }

        let sessionID = UUID()
        do {
            let context = try openStore()
            let service = TagService()
            let session = RecordingSession(
                id: sessionID, duration: 60, micAudioURL: "/tmp/a.wav", title: "S"
            )
            context.insert(session)
            try service.applyDefaultTag(to: session, in: context)
            let work = try service.createTag(name: "Work", in: context)
            let client = try service.createTag(name: "Client", in: context)
            _ = try service.assign(work, to: session, in: context)
            _ = try service.assign(client, to: session, in: context)
            try context.save()

            try service.delete(work, in: context)
        }

        do {
            let context = try openStore()
            let session = try #require(
                try context.fetch(FetchDescriptor<RecordingSession>()).first { $0.id == sessionID }
            )
            #expect(session.tags.map(\.name) == ["Client"])
            #expect(try context.fetch(FetchDescriptor<RecordingTag>()).allSatisfy { $0.name != "Work" })
        }
    }

    // MARK: - Colour

    @Test
    func testGeneratedColoursAreNeitherBlackNorWhite() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let hex = TagColor.randomUsableHex(using: &generator)
            let components = try #require(TagColor.components(fromHex: hex))
            let maximum = max(components.red, components.green, components.blue)
            let minimum = min(components.red, components.green, components.blue)
            // Brightness is the maximum channel; saturation is (max - min) / max.
            #expect(maximum >= TagColor.brightnessRange.lowerBound - 0.01)
            #expect(maximum <= TagColor.brightnessRange.upperBound + 0.01)
            let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
            #expect(saturation >= TagColor.saturationRange.lowerBound - 0.01)
            #expect(saturation <= TagColor.saturationRange.upperBound + 0.01)
        }
    }

    @Test
    func testHexNormalisation() {
        #expect(TagColor.normalizedHex("#ff8800") == "FF8800")
        #expect(TagColor.normalizedHex("  aabbcc  ") == "AABBCC")
        // Unparseable falls back rather than leaving a tag with no colour.
        #expect(TagColor.normalizedHex("nope") == RecordingTag.Defaults.colorHex)
        #expect(TagColor.normalizedHex("FFF") == RecordingTag.Defaults.colorHex)
    }

    @Test
    func testHexRoundTripsThroughComponents() throws {
        let components = try #require(TagColor.components(fromHex: "0A84FF"))
        #expect(abs(components.red - 10.0 / 255) < 0.001)
        #expect(abs(components.green - 132.0 / 255) < 0.001)
        #expect(abs(components.blue - 1.0) < 0.001)
        #expect(TagColor.components(fromHex: "bad") == nil)
    }
}
