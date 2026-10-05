import Testing
import SwiftData
import FluidAudio
import Foundation
@testable import Scriberman

@Suite("SpeakerEmbeddingStore Tests")
struct SpeakerEmbeddingStoreTests {
    private let container: ModelContainer
    private let store: SpeakerEmbeddingStore

    init() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        self.container = try ModelContainer(for: SpeakerProfile.self, SpeakerVoiceprint.self, configurations: config)
        self.store = SpeakerEmbeddingStore(modelContainer: container)
    }

    @Test("Fetch a profile by ID beyond the first 1,000 rows of an on-disk store")
    func fetchProfileByIDBeyondFirstThousand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let onDiskContainer = try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
        )
        let context = ModelContext(onDiskContainer)
        var insertedIDs: [UUID] = []
        for index in 0..<1_500 {
            let profile = SpeakerProfile(name: "Speaker \(index)", embedding: [Float(index)])
            context.insert(profile)
            insertedIDs.append(profile.id)
        }
        try context.save()

        let targetID = insertedIDs[1_400]
        let fetched = try SpeakerProfile.fetch(id: targetID, in: ModelContext(onDiskContainer))

        #expect(fetched?.id == targetID)
        #expect(fetched?.name == "Speaker 1400")
    }

    // MARK: - Voiceprint space reset

    private func isolatedDefaults() -> UserDefaults {
        let suite = "SpeakerEmbeddingStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Start-up reset deletes every profile when no voiceprint space is recorded")
    func resetDeletesProfilesOnMissingMarker() throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0], voiceprintSpace: ""))
        context.insert(SpeakerProfile(name: "Bob", embedding: [0, 1]))
        try context.save()
        let defaults = isolatedDefaults()

        let removed = try SpeakerProfile.resetIfVoiceprintSpaceChanged(in: context, userDefaults: defaults)

        #expect(removed == 2)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SpeakerProfile>()).isEmpty)
        #expect(defaults.string(forKey: SpeakerProfile.voiceprintSpaceMarkerKey) == VoiceprintSpace.current)
    }

    @Test("Start-up reset deletes every profile when another voiceprint space is recorded")
    func resetDeletesProfilesOnOtherSpace() throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0]))
        try context.save()
        let defaults = isolatedDefaults()
        defaults.set("community-1", forKey: SpeakerProfile.voiceprintSpaceMarkerKey)

        let removed = try SpeakerProfile.resetIfVoiceprintSpaceChanged(in: context, userDefaults: defaults)

        #expect(removed == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SpeakerProfile>()).isEmpty)
    }

    @Test("Start-up reset keeps profiles when the recorded voiceprint space is current")
    func resetKeepsProfilesOnCurrentSpace() throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0]))
        try context.save()
        let defaults = isolatedDefaults()
        defaults.set(VoiceprintSpace.current, forKey: SpeakerProfile.voiceprintSpaceMarkerKey)

        let removed = try SpeakerProfile.resetIfVoiceprintSpaceChanged(in: context, userDefaults: defaults)

        #expect(removed == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<SpeakerProfile>()).map(\.name) == ["Alice"])
    }

    @Test("Teach a new speaker")
    func teachNewSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.teach(name: "Alice", voiceprint: embedding)

        let all = try await store.fetchAllSnapshots()
        #expect(all.count == 1)
        #expect(all.first?.name == "Alice")
        #expect(all.first?.embedding == embedding)
    }

    // MARK: - Voiceprint model

    @Test("A voiceprint source round-trips through a stored voiceprint")
    func voiceprintSourceRoundTrips() throws {
        let source = VoiceprintSource(sessionID: UUID(), pass: .retranscript, speakerID: "speaker_2")
        let context = ModelContext(container)
        let voiceprint = SpeakerVoiceprint(embedding: [1, 0], source: source)
        context.insert(voiceprint)
        try context.save()

        let fetched = try #require(try ModelContext(container).fetch(FetchDescriptor<SpeakerVoiceprint>()).first)
        #expect(fetched.source == source)
        #expect(SpeakerVoiceprint(embedding: [1]).source == nil)
    }

    // MARK: - Migration

    @Test("Migration gives a profile one source-less voiceprint weighted by its sample count")
    func migrationCreatesOneWeightedVoiceprint() async throws {
        let context = ModelContext(container)
        let alice = SpeakerProfile(name: "Alice", embedding: [0.6, 0.8, 0], sampleCount: 3)
        context.insert(alice)
        try context.save()

        #expect(try SpeakerProfile.migrateToVoiceprintLists(in: context) == 1)
        #expect(try SpeakerProfile.migrateToVoiceprintLists(in: context) == 0)

        let voiceprints = try await store.voiceprintSnapshots(profileID: alice.id)
        #expect(voiceprints.count == 1)
        #expect(voiceprints.first?.weight == 3)
        #expect(voiceprints.first?.source == nil)
        let profile = try #require(try await store.findProfileSnapshot(byID: alice.id))
        #expect(profile.embedding == [0.6, 0.8, 0])
        #expect(profile.sampleCount == 3)
    }

    @Test("Matching gives the same result before and after the migration")
    func migrationKeepsMatches() async throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0.1, 0], sampleCount: 3))
        context.insert(SpeakerProfile(name: "Bob", embedding: [0, 1, 0.1], sampleCount: 1))
        try context.save()
        let query: [Float] = [0.9, 0.2, 0]
        let before = try #require(await store.findBestMatchSnapshot(embedding: query))

        try SpeakerProfile.migrateToVoiceprintLists(in: context)

        let after = try #require(await store.findBestMatchSnapshot(embedding: query))
        #expect(after.id == before.id)
        #expect(after.embedding == before.embedding)
    }

    // MARK: - Teaching (renames)

    private func source(_ speakerID: String = "speaker_1", session: UUID = UUID(), pass: TranscriptPass = .transcript) -> VoiceprintSource {
        VoiceprintSource(sessionID: session, pass: pass, speakerID: speakerID)
    }

    private func expectClose(_ values: [Float], _ expected: [Float]) {
        #expect(values.count == expected.count)
        for (value, target) in zip(values, expected) {
            #expect(abs(value - target) < 1e-6)
        }
    }

    private func profile(named name: String) async throws -> SpeakerProfileSnapshot? {
        try await store.fetchAllSnapshots().first { $0.name == name }
    }

    @Test("The matching vector is the weighted mean of the voiceprints")
    func matchingVectorIsWeightedMean() async throws {
        let context = ModelContext(container)
        let alice = SpeakerProfile(name: "Alice", embedding: [1, 0, 0], sampleCount: 2)
        context.insert(alice)
        try context.save()
        try SpeakerProfile.migrateToVoiceprintLists(in: context)

        try await store.teach(name: "Alice", source: source(), voiceprints: [[0, 1, 0]])

        let profile = try #require(try await store.findProfileSnapshot(byID: alice.id))
        expectClose(profile.embedding, [2.0 / 3, 1.0 / 3, 0])
        #expect(profile.sampleCount == 3)
    }

    @Test("First-time speaker enrollment stores the voiceprints with their source")
    func firstTimeEnrollment() async throws {
        let taught = source("speaker_2")
        try await store.teach(name: "Alice", source: taught, voiceprints: [[0, 1, 0, 0]])

        let alice = try #require(try await profile(named: "Alice"))
        #expect(alice.embedding == [0, 1, 0, 0])
        #expect(alice.sampleCount == 1)
        #expect(alice.voiceprintSpace == VoiceprintSpace.current)
        let voiceprints = try await store.voiceprintSnapshots(profileID: alice.id)
        #expect(voiceprints.map(\.source) == [taught])
        #expect(voiceprints.map(\.weight) == [1])
    }

    @Test("Rename to an existing profile's name (case-insensitive) adds the voiceprint")
    func teachIntoExistingName() async throws {
        try await store.teach(name: "Alice", source: source(), voiceprints: [[1, 0, 0]])
        try await store.teach(name: "Alice", source: source(), voiceprints: [[0, 1, 0]])

        try await store.teach(name: "alice", source: source(), voiceprints: [[0, 0, 1]])

        let all = try await store.fetchAllSnapshots()
        #expect(all.count == 1)
        let alice = try #require(all.first)
        #expect(alice.name == "Alice")
        #expect(alice.sampleCount == 3)
        expectClose(alice.embedding, [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    /// Spec scenario "Fold order does not matter": three distinct voiceprints taught in every
    /// order, with the store reopened between renames, give the same stored mean and count.
    @Test("Fold order does not matter across saves and reloads")
    func foldOrderDoesNotMatter() async throws {
        let voiceprints: [[Float]] = [
            [1, 0, 0],
            [0.6, 0.8, 0],
            [0, 0.28, 0.96]
        ]
        let sources = (0..<3).map { source("speaker_\($0)") }
        let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        var results: [(embedding: [Float], count: Int)] = []

        for order in orders {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("store.sqlite")
            for index in order {
                // A fresh container per rename: the stored voiceprints are read back from disk each time.
                let onDisk = SpeakerEmbeddingStore(modelContainer: try ModelContainer(
                    for: SpeakerProfile.self, SpeakerVoiceprint.self,
                    configurations: ModelConfiguration(url: url)
                ))
                try await onDisk.teach(name: "Alice", source: sources[index], voiceprints: [voiceprints[index]])
            }
            let reopened = SpeakerEmbeddingStore(modelContainer: try ModelContainer(
                for: SpeakerProfile.self, SpeakerVoiceprint.self,
                configurations: ModelConfiguration(url: url)
            ))
            let profile = try #require(try await reopened.fetchAllSnapshots().first)
            results.append((profile.embedding, profile.sampleCount))
        }

        for result in results {
            #expect(result.count == 3)
            expectClose(result.embedding, [1.6 / 3, 1.08 / 3, 0.96 / 3])
        }
    }

    @Test("Wrong name corrected by renaming again moves the voiceprints")
    func renameAgainMovesVoiceprints() async throws {
        let speaker = source("speaker_2")
        try await store.teach(name: "Bob", source: speaker, voiceprints: [[0, 1]])

        try await store.teach(name: "Carol", source: speaker, voiceprints: [[0, 1]])

        let all = try await store.fetchAllSnapshots()
        #expect(all.map(\.name) == ["Carol"])
        #expect(all.first?.sampleCount == 1)
    }

    @Test("Renaming again keeps the old profile's other voiceprints")
    func renameAgainKeepsOtherVoiceprints() async throws {
        try await store.teach(name: "Bob", source: source(), voiceprints: [[1, 0]])
        try await store.teach(name: "Bob", source: source(), voiceprints: [[1, 0.2]])
        let speaker = source("speaker_2")
        try await store.teach(name: "Bob", source: speaker, voiceprints: [[0, 1]])

        try await store.teach(name: "Carol", source: speaker, voiceprints: [[0, 1]])

        let bob = try #require(try await profile(named: "Bob"))
        #expect(bob.sampleCount == 2)
        expectClose(bob.embedding, [1, 0.1])
        #expect(try await profile(named: "Carol")?.sampleCount == 1)
    }

    @Test("A rename of a speaker matched to another profile leaves that profile unchanged")
    func renameMatchedSpeakerKeepsMatchedProfile() async throws {
        let aliceID = try await store.teach(name: "Alice", voiceprint: [1, 0])

        try await store.teach(name: "Carol", source: source(), voiceprints: [[0.9, 0.1]])

        let alice = try #require(try await store.findProfileSnapshot(byID: aliceID))
        #expect(alice.embedding == [1, 0])
        #expect(alice.sampleCount == 1)
    }

    @Test("Same source taught twice is held once")
    func sameSourceTaughtTwice() async throws {
        let speaker = source("speaker_2")
        try await store.teach(name: "Bob", source: speaker, voiceprints: [[0, 1]])
        try await store.teach(name: "Carol", source: speaker, voiceprints: [[0, 1]])
        try await store.teach(name: "Bob", source: speaker, voiceprints: [[0, 1]])

        let all = try await store.fetchAllSnapshots()
        #expect(all.map(\.name) == ["Bob"])
        #expect(all.first?.sampleCount == 1)
    }

    @Test("A source with the same speaker ID in the other pass is a different source")
    func passIsPartOfTheSource() async throws {
        let session = UUID()
        try await store.teach(name: "Bob", source: source("speaker_1", session: session, pass: .transcript), voiceprints: [[1, 0]])

        try await store.teach(name: "Carol", source: source("speaker_1", session: session, pass: .retranscript), voiceprints: [[0, 1]])

        #expect(Set(try await store.fetchAllSnapshots().map(\.name)) == ["Bob", "Carol"])
    }

    @Test("Teaching a profile from another voiceprint space replaces its voiceprints")
    func teachIntoOtherSpaceProfileReplaces() async throws {
        let context = ModelContext(container)
        context.insert(SpeakerProfile(name: "Alice", embedding: [1, 0], voiceprintSpace: "", sampleCount: 4))
        try context.save()
        try SpeakerProfile.migrateToVoiceprintLists(in: context)

        try await store.teach(name: "Alice", source: source(), voiceprints: [[0, 1]])

        let profile = try #require(try await store.fetchAllSnapshots().first)
        #expect(profile.embedding == [0, 1])
        #expect(profile.sampleCount == 1)
        #expect(profile.voiceprintSpace == VoiceprintSpace.current)
    }

    // MARK: - Reset

    @Test("Reset after a wrong rename removes the voiceprint it taught")
    func resetAfterWrongRename() async throws {
        try await store.teach(name: "Bob", source: source(), voiceprints: [[1, 0]])
        let speaker = source("speaker_2")
        try await store.teach(name: "Bob", source: speaker, voiceprints: [[0, 1]])

        try await store.forget(source: speaker)

        let bob = try #require(try await profile(named: "Bob"))
        #expect(bob.sampleCount == 1)
        #expect(bob.embedding == [1, 0])
    }

    @Test("Reset of a matched speaker leaves the matched profile unchanged")
    func resetMatchedSpeaker() async throws {
        let aliceID = try await store.teach(name: "Alice", voiceprint: [1, 0])

        try await store.forget(source: source())

        let alice = try #require(try await store.findProfileSnapshot(byID: aliceID))
        #expect(alice.sampleCount == 1)
    }

    @Test("Reset of a speaker's only voiceprint deletes the profile")
    func resetDeletesEmptyProfile() async throws {
        let speaker = source()
        try await store.teach(name: "Bob", source: speaker, voiceprints: [[1, 0]])

        try await store.forget(source: speaker)

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    // MARK: - Speaker merge

    @Test("Merge into a named speaker teaches that speaker's profile")
    func mergeIntoNamedSpeaker() async throws {
        let session = UUID()
        for index in 0..<4 {
            try await store.teach(name: "Alice", source: source("other_\(index)"), voiceprints: [[1, Float(index)]])
        }
        let speaker3 = source("speaker_3", session: session)
        let alice = source("speaker_1", session: session)

        try await store.retarget(from: speaker3, to: alice, name: "Alice", voiceprints: [[0, 1]])

        #expect(try await profile(named: "Alice")?.sampleCount == 5)
    }

    @Test("Merge into an unnamed speaker teaches nothing")
    func mergeIntoUnnamedSpeaker() async throws {
        try await store.teach(name: "Alice", voiceprint: [1, 0])

        try await store.retarget(from: source("speaker_3"), to: source("speaker_1"), name: nil, voiceprints: [[0, 1]])

        #expect(try await store.fetchAllSnapshots().map(\.sampleCount) == [1])
    }

    @Test("Merging a named speaker removes what it taught")
    func mergeRemovesWhatTheMergedSpeakerTaught() async throws {
        let session = UUID()
        let speaker3 = source("speaker_3", session: session)
        try await store.teach(name: "Bob", source: speaker3, voiceprints: [[0, 1]])

        try await store.retarget(from: speaker3, to: source("speaker_1", session: session), name: nil, voiceprints: [[0, 1]])

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test("Reset after merge removes what both speakers taught")
    func resetAfterMerge() async throws {
        let session = UUID()
        let alice = source("speaker_1", session: session)
        let speaker3 = source("speaker_3", session: session)
        try await store.teach(name: "Alice", source: source("other"), voiceprints: [[1, 0]])
        try await store.teach(name: "Alice", source: alice, voiceprints: [[1, 0.1]])
        try await store.retarget(from: speaker3, to: alice, name: "Alice", voiceprints: [[0.9, 0.2]])
        #expect(try await profile(named: "Alice")?.sampleCount == 3)

        try await store.forget(source: alice)

        let remaining = try #require(try await profile(named: "Alice"))
        #expect(remaining.sampleCount == 1)
        #expect(remaining.embedding == [1, 0])
    }

    // MARK: - Profile merge and voiceprint removal

    @Test("Duplicate profiles joined")
    func duplicateProfilesJoined() async throws {
        for index in 0..<2 {
            try await store.teach(name: "alice", source: source("lower_\(index)"), voiceprints: [[1, Float(index)]])
        }
        // Teaching is case-insensitive, so the second profile is taught under another name first.
        for index in 0..<12 {
            try await store.teach(name: "Upper", source: source("upper_\(index)"), voiceprints: [[Float(index), 1]])
        }
        let upperID = try #require(try await profile(named: "Upper")?.id)
        try await store.renameProfile(id: upperID, name: "Alice")
        let all = try await store.fetchAllSnapshots()
        let lower = try #require(all.first { $0.name == "alice" })
        let upper = try #require(all.first { $0.name == "Alice" })
        #expect(lower.sampleCount == 2)
        #expect(upper.sampleCount == 12)

        try await store.mergeProfile(id: lower.id, into: upper.id)

        let merged = try await store.fetchAllSnapshots()
        #expect(merged.map(\.name) == ["Alice"])
        #expect(merged.first?.id == upper.id)
        #expect(merged.first?.sampleCount == 14)
    }

    @Test("A profile merge skips a source the target already holds")
    func profileMergeSkipsDuplicateSource() async throws {
        let shared = source()
        try await store.teach(name: "Alice", source: shared, voiceprints: [[1, 0]])
        let aliceID = try #require(try await profile(named: "Alice")?.id)
        // A second profile holding the same source cannot come from teach, so build it directly.
        let context = ModelContext(container)
        let other = SpeakerProfile(name: "alice", embedding: [1, 0])
        context.insert(other)
        let duplicate = SpeakerVoiceprint(embedding: [1, 0], source: shared)
        context.insert(duplicate)
        other.voiceprints.append(duplicate)
        try context.save()

        try await store.mergeProfile(id: other.id, into: aliceID)

        #expect(try await store.voiceprintSnapshots(profileID: aliceID).count == 1)
    }

    @Test("Remove one voiceprint")
    func removeOneVoiceprint() async throws {
        let weeklySync = source()
        try await store.teach(name: "Bob", source: weeklySync, voiceprints: [[1, 0, 0]])
        try await store.teach(name: "Bob", source: source(), voiceprints: [[0, 1, 0]])
        try await store.teach(name: "Bob", source: source(), voiceprints: [[0, 0, 1]])
        let bobID = try #require(try await profile(named: "Bob")?.id)
        let removed = try #require(try await store.voiceprintSnapshots(profileID: bobID).first { $0.source == weeklySync })

        try await store.removeVoiceprint(id: removed.id)

        let bob = try #require(try await store.findProfileSnapshot(byID: bobID))
        #expect(bob.sampleCount == 2)
        expectClose(bob.embedding, [0, 0.5, 0.5])
    }

    @Test("Remove the last voiceprint")
    func removeLastVoiceprint() async throws {
        let bobID = try await store.teach(name: "Bob", voiceprint: [1, 0])
        let voiceprint = try #require(try await store.voiceprintSnapshots(profileID: bobID).first)

        try await store.removeVoiceprint(id: voiceprint.id)

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test("Deleting a profile deletes its voiceprints")
    func deletingProfileDeletesVoiceprints() async throws {
        let bobID = try await store.teach(name: "Bob", voiceprint: [1, 0])

        try await store.deleteProfile(id: bobID)

        #expect(try ModelContext(container).fetch(FetchDescriptor<SpeakerVoiceprint>()).isEmpty)
    }

    @Test("The store matches nothing on a tie, as SpeakerMatcher does")
    func findBestMatchTieMatchesNothing() async throws {
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0
        let first = try await store.teach(name: "First", voiceprint: embedding)
        try await store.teach(name: "Second", voiceprint: embedding)
        try await store.updateProfile(id: first)

        let match = await store.findBestMatchSnapshot(embedding: embedding)

        #expect(match == nil)
    }

    // MARK: - Concurrency

    @Test("Match, enroll and delete run concurrently on an on-disk store")
    func concurrentMatchEnrollDelete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let onDisk = SpeakerEmbeddingStore(modelContainer: try ModelContainer(
            for: SpeakerProfile.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
        ))
        let axis: [Float] = [1] + Array(repeating: 0, count: 255)
        let toDelete = try await (0..<20).asyncMap { _ in try await onDisk.teach(name: "Doomed", voiceprint: axis) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<50 { _ = await onDisk.findBestMatchSnapshot(embedding: axis) }
            }
            group.addTask {
                for index in 1...20 { try await onDisk.teach(name: "Speaker \(index)", voiceprint: axis) }
            }
            group.addTask {
                for id in toDelete { try await onDisk.deleteProfile(id: id) }
            }
            try await group.waitForAll()
        }

        let names = try await onDisk.fetchAllSnapshots().map(\.name)
        #expect(names.count == 20)
        #expect(!names.contains("Doomed"))
        #expect(Set(names) == Set((1...20).map { "Speaker \($0)" }))
    }

    @Test("Delete a speaker profile")
    func deleteSpeaker() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.teach(name: "Alice", voiceprint: embedding)
        
        let all = try await store.fetchAllSnapshots()
        let firstId = try #require(all.first?.id)
        try await store.deleteProfile(id: firstId)
        
        let allAfter = try await store.fetchAllSnapshots()
        #expect(allAfter.isEmpty)
    }

    @Test("Find a profile by ID")
    func findProfileByID() async throws {
        let embedding: [Float] = Array(repeating: 0.1, count: 256)
        try await store.teach(name: "Alice", voiceprint: embedding)

        let all = try await store.fetchAllSnapshots()
        let id = try #require(all.first?.id)

        let found = try await store.findProfileSnapshot(byID: id)
        #expect(found != nil)
        #expect(found?.name == "Alice")
    }

    // MARK: - findBestMatch (task 6.1)

    @Test("findBestMatch returns matching profile when similarity meets threshold")
    func findBestMatchReturnsMatchAboveThreshold() async throws {
        // Normalised unit vector along first axis
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0
        try await store.teach(name: "Alice", voiceprint: embedding)

        // Query is the same vector — cosine similarity == 1.0
        let match = await store.findBestMatchSnapshot(embedding: embedding)
        #expect(match?.name == "Alice")
    }

    @Test("findBestMatch returns nil when best similarity is below threshold")
    func findBestMatchReturnsNilBelowThreshold() async throws {
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        try await store.teach(name: "Alice", voiceprint: alice)

        // Orthogonal vector — cosine similarity == 0.0
        var query: [Float] = Array(repeating: 0.0, count: 256)
        query[1] = 1.0

        let match = await store.findBestMatchSnapshot(embedding: query)
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil when store is empty")
    func findBestMatchReturnsNilForEmptyStore() async {
        var embedding: [Float] = Array(repeating: 0.0, count: 256)
        embedding[0] = 1.0

        let match = await store.findBestMatchSnapshot(embedding: embedding)
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil for zero-length embedding")
    func findBestMatchReturnsNilForZeroLengthEmbedding() async throws {
        var stored: [Float] = Array(repeating: 0.0, count: 256)
        stored[0] = 1.0
        try await store.teach(name: "Alice", voiceprint: stored)

        let match = await store.findBestMatchSnapshot(embedding: [])
        #expect(match == nil)
    }

    @Test("findBestMatch returns nil for all-zeros embedding")
    func findBestMatchReturnsNilForZeroEmbedding() async throws {
        var stored: [Float] = Array(repeating: 0.0, count: 256)
        stored[0] = 1.0
        try await store.teach(name: "Alice", voiceprint: stored)

        let zeroEmbedding: [Float] = Array(repeating: 0.0, count: 256)
        let match = await store.findBestMatchSnapshot(embedding: zeroEmbedding)
        #expect(match == nil)
    }

    @Test("findBestMatch returns the highest-similarity profile when multiple exist")
    func findBestMatchReturnsBestAmongMultiple() async throws {
        // Alice: unit vector on axis 0
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        try await store.teach(name: "Alice", voiceprint: alice)

        // Bob: unit vector on axis 1
        var bob: [Float] = Array(repeating: 0.0, count: 256)
        bob[1] = 1.0
        try await store.teach(name: "Bob", voiceprint: bob)

        // Query close to Alice (small perturbation on axis 0)
        var query: [Float] = Array(repeating: 0.0, count: 256)
        query[0] = 0.99
        query[1] = 0.01

        let match = await store.findBestMatchSnapshot(embedding: query)
        #expect(match?.name == "Alice")
    }

    @Test("Rename a profile keeps its voiceprint")
    func renameProfileKeepsVoiceprint() async throws {
        let id = try await store.teach(name: "Speaker 5", voiceprint: [0.5, 0.5])

        try await store.renameProfile(id: id, name: "Bob")

        let profile = try await store.findProfileSnapshot(byID: id)
        #expect(profile?.name == "Bob")
        #expect(profile?.embedding == [0.5, 0.5])
        #expect(try await store.fetchAllSnapshots().count == 1)
    }

    @Test("Delete all profiles empties the store")
    func deleteAllProfilesEmptiesStore() async throws {
        try await store.teach(name: "Alice", voiceprint: [0.1])
        try await store.teach(name: "Bob", voiceprint: [0.2])

        try await store.deleteAllProfiles()

        #expect(try await store.fetchAllSnapshots().isEmpty)
    }

    @Test("A deleted profile is no longer matched")
    func deletedProfileIsNotMatched() async throws {
        var alice: [Float] = Array(repeating: 0.0, count: 256)
        alice[0] = 1.0
        let aliceID = try await store.teach(name: "Alice", voiceprint: alice)
        #expect(await store.findBestMatchSnapshot(embedding: alice)?.name == "Alice")

        try await store.deleteProfile(id: aliceID)

        #expect(await store.findBestMatchSnapshot(embedding: alice) == nil)
    }
}

@MainActor
struct SpeakerProfileListTests {
    private struct DeleteFailure: Error {}

    private func snapshot(_ name: String) -> SpeakerProfileSnapshot {
        SpeakerProfileSnapshot(profile: SpeakerProfile(name: name, embedding: [0.1]))
    }

    @Test
    func failedDeleteReloadsAndShowsFailureUntilADeleteSucceeds() async {
        let bob = snapshot("Bob")
        let list = SpeakerProfileList(fetch: { [bob] })

        await list.delete { throw DeleteFailure() }
        #expect(list.deleteFailed)
        #expect(list.profiles.map(\.name) == ["Bob"])
        #expect(list.isLoading == false)

        await list.delete {}
        #expect(list.deleteFailed == false)
    }

    @Test
    func successfulDeleteReloadsFromStorage() async throws {
        let container = try ModelContainer(for: SpeakerProfile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = SpeakerEmbeddingStore(modelContainer: container)
        let aliceID = try await store.teach(name: "Alice", voiceprint: [0.1])
        try await store.teach(name: "Bob", voiceprint: [0.2])
        let list = SpeakerProfileList(store: store)
        await list.load()

        await list.delete { try await store.deleteProfile(id: aliceID) }

        #expect(list.profiles.map(\.name) == ["Bob"])
        #expect(list.deleteFailed == false)
    }

    private func storeAndList() async throws -> (SpeakerEmbeddingStore, SpeakerProfileList) {
        let container = try ModelContainer(for: SpeakerProfile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = SpeakerEmbeddingStore(modelContainer: container)
        return (store, SpeakerProfileList(store: store))
    }

    /// Spec scenario "Rename a profile".
    @Test
    func renameToAFreeNameRenames() async throws {
        let (store, list) = try await storeAndList()
        let bobID = try await store.teach(name: "Bob", voiceprint: [1, 0])
        await list.load()

        #expect(await list.rename(bobID, to: " Robert ") == .renamed)
        #expect(list.profiles.map(\.name) == ["Robert"])
        #expect(await list.rename(bobID, to: "Robert") == .unchanged)
        #expect(await list.rename(bobID, to: "  ") == .unchanged)
    }

    /// Spec scenarios "Merge confirmed" and "Merge cancelled".
    @Test
    func renameToATakenNameAsksForAMergeAndMergeJoins() async throws {
        let (store, list) = try await storeAndList()
        let lowerID = try await store.teach(name: "alice", voiceprint: [1, 0])
        try await store.teach(name: "alice", voiceprint: [1, 0.1])
        let upperID = try await store.teach(name: "Upper", voiceprint: [0, 1])
        try await store.renameProfile(id: upperID, name: "Alice")
        await list.load()

        #expect(await list.rename(lowerID, to: "Alice") == .needsMerge(targetID: upperID))
        #expect(Set(list.profiles.map(\.name)) == ["alice", "Alice"])

        await list.merge(lowerID, into: upperID)

        #expect(list.profiles.map(\.name) == ["Alice"])
        #expect(list.profiles.map(\.sampleCount) == [3])
        #expect(SpeakerProfileList.voiceprintCountText(3) == "3 voiceprints")
        #expect(SpeakerProfileList.voiceprintCountText(1) == "1 voiceprint")
    }

    /// Spec scenarios "Remove a voiceprint" and "Remove the last voiceprint".
    @Test
    func removingVoiceprintsReducesTheCountThenDeletesTheProfile() async throws {
        let (store, list) = try await storeAndList()
        let bobID = try await store.teach(name: "Bob", voiceprint: [1, 0])
        try await store.teach(name: "Bob", voiceprint: [0, 1])
        await list.load()
        let voiceprints = await list.voiceprints(of: bobID)
        #expect(voiceprints.count == 2)

        await list.removeVoiceprint(voiceprints[0].id)
        #expect(list.profiles.map(\.sampleCount) == [1])

        await list.removeVoiceprint(voiceprints[1].id)
        #expect(list.profiles.isEmpty)
    }
}

extension SpeakerEmbeddingStore {
    /// Teaches `name` one voiceprint from a fresh source, as a rename in a new session would.
    @discardableResult
    func teach(name: String, voiceprint: [Float]) throws -> UUID {
        try teach(
            name: name,
            source: VoiceprintSource(sessionID: UUID(), pass: .transcript, speakerID: "speaker_1"),
            voiceprints: [voiceprint]
        )
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
