import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// The backfill runs once at startup over a store nobody can size in advance, so what matters is
/// that it touches only what needs touching and that a second launch is free.
@MainActor
final class SessionSearchTextBackfillTests {
    private let storeDirectory: URL

    init() throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            SpeakerProfile.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeOnDiskContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            SpeakerProfile.self, RecordingTag.self,
            configurations: ModelConfiguration(url: storeDirectory.appendingPathComponent("store.sqlite"))
        )
    }

    private func transcriptData(_ text: String) throws -> Data {
        try JSONEncoder().encode(
            Transcript(
                fullText: text,
                segments: [TranscriptSegment(speakerId: "A", text: text, startTime: 0, endTime: 1)],
                speakers: []
            )
        )
    }

    /// A session as it exists before this change: transcript blobs, no searchable text.
    private func makeLegacyRecording(
        in context: ModelContext,
        title: String = "Session",
        transcript: String?,
        retranscript: String? = nil
    ) throws -> RecordingSession {
        let session = RecordingSession(
            duration: 60,
            micAudioURL: "/tmp/mic.wav",
            title: title,
            transcriptData: try transcript.map(transcriptData),
            retranscriptData: try retranscript.map(transcriptData)
        )
        session.searchableText = nil
        context.insert(session)
        return session
    }

    private func makeLegacyImport(
        in context: ModelContext,
        transcript: String?
    ) throws -> ImportedSession {
        let session = ImportedSession(
            duration: 60,
            title: "Import",
            originalFileName: "clip.mp3",
            originalFormat: "mp3",
            transcriptData: try transcript.map(transcriptData)
        )
        session.searchableText = nil
        context.insert(session)
        return session
    }

    // MARK: - What it touches

    @Test
    func testSessionsHoldingATranscriptAreBackfilled() throws {
        let context = try makeInMemoryContext()
        let recording = try makeLegacyRecording(in: context, transcript: "the migration is next week")
        let imported = try makeLegacyImport(in: context, transcript: "a conference recording")

        let result = try SessionSearchTextBackfill().backfill(in: context)

        #expect(result.recordingsUpdated == 1)
        #expect(result.importsUpdated == 1)
        #expect(recording.searchableText == "the migration is next week")
        #expect(imported.searchableText == "a conference recording")
    }

    @Test
    func testBackfillFollowsTheDisplayedPass() throws {
        let context = try makeInMemoryContext()
        let session = try makeLegacyRecording(
            in: context,
            transcript: "first pass",
            retranscript: "second pass"
        )

        _ = try SessionSearchTextBackfill().backfill(in: context)

        #expect(session.searchableText == "second pass")
    }

    @Test
    func testASessionWithNoTranscriptIsUntouched() throws {
        let context = try makeInMemoryContext()
        let session = try makeLegacyRecording(in: context, transcript: nil)

        let result = try SessionSearchTextBackfill().backfill(in: context)

        #expect(result.totalUpdated == 0)
        #expect(session.searchableText == nil)
    }

    @Test
    func testASessionThatAlreadyHasItsTextIsUntouched() throws {
        let context = try makeInMemoryContext()
        let session = try makeLegacyRecording(in: context, transcript: "already indexed")
        session.searchableText = "edited by hand"

        let result = try SessionSearchTextBackfill().backfill(in: context)

        #expect(result.totalUpdated == 0)
        #expect(session.searchableText == "edited by hand")
    }

    @Test
    func testASecondRunChangesNothing() throws {
        let context = try makeInMemoryContext()
        _ = try makeLegacyRecording(in: context, transcript: "the migration is next week")
        _ = try makeLegacyImport(in: context, transcript: "a conference recording")

        let backfill = SessionSearchTextBackfill()
        let first = try backfill.backfill(in: context)
        let second = try backfill.backfill(in: context)

        #expect(first.totalUpdated == 2)
        #expect(second.totalUpdated == 0)
    }

    // MARK: - Against a store on disk

    @Test
    func testBackfilledTextSurvivesReopeningTheStore() throws {
        let container = try makeOnDiskContainer()
        let context = ModelContext(container)
        let id = try makeLegacyRecording(in: context, transcript: "said out loud once").id
        let importID = try makeLegacyImport(in: context, transcript: "imported and transcribed").id
        try context.save()

        let result = try SessionSearchTextBackfill().backfill(in: context)
        #expect(result.totalUpdated == 2)

        // A fresh context over the same file: the text was written, not just held in memory.
        let reopened = ModelContext(try makeOnDiskContainer())
        let recordings = try reopened.fetch(
            FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == id })
        )
        let imports = try reopened.fetch(
            FetchDescriptor<ImportedSession>(predicate: #Predicate { $0.id == importID })
        )

        #expect(recordings.first?.searchableText == "said out loud once")
        #expect(imports.first?.searchableText == "imported and transcribed")

        // And the launch after that has nothing left to do.
        #expect(try SessionSearchTextBackfill().backfill(in: reopened).totalUpdated == 0)
    }

    // MARK: - Cost

    @Test
    func testTheRunReportsHowLongItTook() throws {
        let context = try makeInMemoryContext()
        _ = try makeLegacyRecording(in: context, transcript: "measured")

        let tick = Counter()
        let backfill = SessionSearchTextBackfill(now: {
            Date(timeIntervalSince1970: TimeInterval(tick.next()))
        })

        #expect(try backfill.backfill(in: context).duration == 1)
    }

    /// A clock the injected closure can advance from whatever thread calls it.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }
}
