import Foundation
import SwiftData
import Testing
@testable import Scriberman

struct RecordingTranscriptPersistenceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    // MARK: - Segment SwiftData persistence

    @Test
    func testTranscriptSegmentPersistsInSwiftData() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = RecordingSession(createdAt: .now, duration: 10, micAudioURL: "/tmp/mic.wav", title: "Test", status: .recording)
        context.insert(session)
        let segment = RecordingTranscriptSegment(
            speakerId: "S1",
            text: "Hello",
            startTime: 0,
            endTime: 2,
            audioSource: .mic,
            isFinal: true,
            session: session
        )
        context.insert(segment)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RecordingTranscriptSegment>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.speakerId == "S1")
        #expect(fetched.first?.text == "Hello")
    }

    @Test
    func testTranscriptSegmentIsLinkedToSession() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = RecordingSession(createdAt: .now, duration: 10, micAudioURL: "/tmp/mic.wav", title: "Test", status: .recording)
        context.insert(session)
        let segment = RecordingTranscriptSegment(
            speakerId: "S2",
            text: "World",
            startTime: 1,
            endTime: 3,
            audioSource: .mic,
            isFinal: true,
            session: session
        )
        context.insert(segment)
        try context.save()

        let fetchedSessions = try context.fetch(FetchDescriptor<RecordingSession>())
        #expect(fetchedSessions.first?.transcriptSegments.count == 1)
        #expect(fetchedSessions.first?.transcriptSegments.first?.text == "World")
    }

    // MARK: - transcript.md append behavior

    @Test
    func testAppendCreatesFileWithHeaderWhenMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        let session = RecordingSession(
            createdAt: .now, duration: 0, micAudioURL: micPath, title: "T", status: .recording
        )
        let segment = RecordingTranscriptSegment(
            speakerId: "S1",
            text: "Hello",
            startTime: 1.5,
            endTime: 3.25,
            audioSource: .mic,
            isFinal: true,
            session: session
        )

        appendTranscriptSegmentToMarkdown(segment, for: session)

        let transcriptURL = tmpDir.appendingPathComponent("transcript.md")
        let contents = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(contents.hasPrefix("# Transcript\n\n"))
        #expect(contents.contains("[1.50-3.25] S1: Hello"))
    }

    @Test
    func testAppendAddsLineToExistingFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let transcriptURL = tmpDir.appendingPathComponent("transcript.md")
        try "# Transcript\n\n[0.00-1.00] S1: First line\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        let session = RecordingSession(
            createdAt: .now, duration: 0, micAudioURL: micPath, title: "T", status: .recording
        )
        let segment = RecordingTranscriptSegment(
            speakerId: "S2",
            text: "Second line",
            startTime: 2.0,
            endTime: 4.0,
            audioSource: .mic,
            isFinal: true,
            session: session
        )

        appendTranscriptSegmentToMarkdown(segment, for: session)

        let contents = try String(contentsOf: transcriptURL, encoding: .utf8)
        #expect(contents.contains("[0.00-1.00] S1: First line"))
        #expect(contents.contains("[2.00-4.00] S2: Second line"))
    }

    @Test
    func testFormatTranscriptTimestampClampsToZero() {
        #expect(formatTranscriptTimestamp(-1.5) == "0.00")
        #expect(formatTranscriptTimestamp(0) == "0.00")
        #expect(formatTranscriptTimestamp(12.345) == "12.35")
    }

    // MARK: - Lookup by ID

    private func makeOnDiskContainer(at directory: URL) throws -> ModelContainer {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("store.sqlite"))
        )
    }

    @Test
    func testRecordingSessionFetchByIDFindsRowBeyondFirstThousand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeOnDiskContainer(at: directory)
        let context = ModelContext(container)
        var insertedIDs: [UUID] = []
        for index in 0..<1_500 {
            let session = RecordingSession(duration: 0, micAudioURL: "/tmp/mic-\(index).wav", title: "Recording \(index)", status: .recorded)
            context.insert(session)
            insertedIDs.append(session.id)
        }
        try context.save()

        let targetID = insertedIDs[1_400]
        let fetched = try RecordingSession.fetch(id: targetID, in: ModelContext(container))

        #expect(fetched?.id == targetID)
        #expect(fetched?.title == "Recording 1400")
    }

    @Test
    func testImportedSessionFetchByIDFindsRowBeyondFirstThousand() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeOnDiskContainer(at: directory)
        let context = ModelContext(container)
        var insertedIDs: [UUID] = []
        for index in 0..<1_500 {
            let session = ImportedSession(duration: 0, title: "Import \(index)", originalFileName: "file-\(index).mp3", originalFormat: "mp3")
            context.insert(session)
            insertedIDs.append(session.id)
        }
        try context.save()

        let targetID = insertedIDs[1_400]
        let fetched = try ImportedSession.fetch(id: targetID, in: ModelContext(container))

        #expect(fetched?.id == targetID)
        #expect(fetched?.title == "Import 1400")
    }

    // MARK: - Cascade

    @Test
    func testDeletingARecordingDeletesItsSegmentsOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        func open() throws -> ModelContext {
            ModelContext(try ModelContainer(
                for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self, RecordingTag.self,
                configurations: ModelConfiguration(url: url)
            ))
        }

        var context = try open()
        let tag = RecordingTag(name: "Work", colorHex: "#FF0000")
        let deleted = RecordingSession(duration: 10, micAudioURL: "/tmp/a/mic.wav", title: "Deleted")
        let kept = RecordingSession(duration: 10, micAudioURL: "/tmp/b/mic.wav", title: "Kept")
        context.insert(tag)
        context.insert(deleted)
        context.insert(kept)
        deleted.tags = [tag]
        kept.tags = [tag]
        for index in 0..<3 {
            context.insert(RecordingTranscriptSegment(
                speakerId: "S1", text: "deleted \(index)", startTime: Float(index), endTime: Float(index + 1),
                audioSource: .mic, session: deleted
            ))
        }
        context.insert(RecordingTranscriptSegment(
            speakerId: "S1", text: "kept", startTime: 0, endTime: 1, audioSource: .mic, session: kept
        ))
        try context.save()

        context.delete(deleted)
        try context.save()

        context = try open()
        let segments = try context.fetch(FetchDescriptor<RecordingTranscriptSegment>())
        let recordings = try context.fetch(FetchDescriptor<RecordingSession>())
        let tags = try context.fetch(FetchDescriptor<RecordingTag>())
        #expect(segments.map(\.text) == ["kept"])
        #expect(recordings.map(\.title) == ["Kept"])
        #expect(tags.map(\.name) == ["Work"])
        #expect(tags.first?.recordings.map(\.title) == ["Kept"])
    }

    @Test @MainActor
    func testStartupRemovesOrphanedSegmentsOnly() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/mic.wav", title: "Owner")
        context.insert(session)
        context.insert(RecordingTranscriptSegment(
            speakerId: "S1", text: "owned", startTime: 0, endTime: 1, audioSource: .mic, session: session
        ))
        for index in 0..<2 {
            context.insert(RecordingTranscriptSegment(
                speakerId: "S1", text: "orphan \(index)", startTime: 0, endTime: 1, audioSource: .mic
            ))
        }
        try context.save()

        ScribermanApp.removeOrphanedTranscriptSegments(in: context)
        ScribermanApp.removeOrphanedTranscriptSegments(in: context)

        let remaining = try ModelContext(container).fetch(FetchDescriptor<RecordingTranscriptSegment>())
        #expect(remaining.map(\.text) == ["owned"])
    }

    // MARK: - Voiceprint space

    /// A transcript saved before voiceprint spaces existed decodes with no space.
    @Test
    func testTranscriptWithoutVoiceprintSpaceDecodesAsNil() throws {
        let json = #"{"fullText":"Hi","segments":[],"speakers":[],"speakerEmbeddings":{"S1":[1,0]}}"#
        let transcript = try JSONDecoder().decode(Transcript.self, from: Data(json.utf8))
        #expect(transcript.voiceprintSpace == nil)
        #expect(transcript.speakerEmbeddings?["S1"] == [1, 0])
    }

    @Test
    func testTranscriptVoiceprintSpaceRoundTrips() throws {
        let transcript = Transcript(
            fullText: "Hi",
            segments: [],
            speakers: [],
            speakerEmbeddings: ["S1": [1, 0]],
            voiceprintSpace: VoiceprintSpace.current
        )
        let decoded = try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript))
        #expect(decoded == transcript)
        #expect(decoded.voiceprintSpace == VoiceprintSpace.current)
    }
}
