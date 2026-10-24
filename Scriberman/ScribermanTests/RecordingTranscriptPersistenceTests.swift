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
        let renderer = MarkdownRenderer()
        #expect(contents.hasPrefix(renderer.header(for: session)))
        #expect(contents.hasSuffix("\n**Mic** [00:01 – 00:03]\nHello\n"))
        #expect(!contents.contains("S1"))
    }

    @Test
    func testAppendAddsLineToExistingFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        let session = RecordingSession(
            createdAt: .now, duration: 0, micAudioURL: micPath, title: "T", status: .recording
        )
        let transcriptURL = tmpDir.appendingPathComponent("transcript.md")
        let existing = MarkdownRenderer().renderMarkdown(
            session: session,
            rows: [MarkdownRenderer.Row(label: "Mic", text: "First line", startTime: 0, endTime: 1)]
        )
        try existing.write(to: transcriptURL, atomically: true, encoding: .utf8)
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
        #expect(contents == existing + "\n**Mic** [00:02 – 00:04]\nSecond line\n")
    }

    /// Appending segment by segment and rewriting from the same segments produce the same file.
    @Test
    func testAppendedFileEqualsRewrite() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        context.insert(session)
        let segments = [
            RecordingTranscriptSegment(
                createdAt: Date(timeIntervalSince1970: 0),
                speakerId: "speaker_mic_0", text: "from the mic", startTime: 0, endTime: 1, audioSource: .mic,
                session: session
            ),
            RecordingTranscriptSegment(
                createdAt: Date(timeIntervalSince1970: 1),
                speakerId: "speaker_app_0", text: "from the app", startTime: 1, endTime: 2, audioSource: .app,
                session: session
            )
        ]
        for segment in segments {
            context.insert(segment)
            appendTranscriptSegmentToMarkdown(segment, for: session)
        }
        try context.save()
        let appended = try String(contentsOf: markdownURL, encoding: .utf8)

        rewriteTranscriptMarkdown(for: session)

        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == appended)
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

    // MARK: - transcript.md shows the app's labels

    private func markdownSession() throws -> (RecordingSession, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = RecordingSession(
            createdAt: .now, duration: 10, micAudioURL: directory.appendingPathComponent("mic.wav").path, title: "T"
        )
        return (session, directory, directory.appendingPathComponent("transcript.md"))
    }

    private func labelledTranscript(firstLabel: String) -> Transcript {
        Transcript(
            fullText: "one two",
            segments: [
                TranscriptSegment(speakerId: "speaker_mic_0", text: "one", startTime: 0, endTime: 1, audioSource: .mic),
                TranscriptSegment(speakerId: "Alice", text: "two", startTime: 1, endTime: 2, audioSource: .app)
            ],
            speakers: [
                TranscriptSpeaker(id: "Alice", label: "Alice", colorHex: "#111111"),
                TranscriptSpeaker(id: "speaker_mic_0", label: firstLabel, colorHex: "#222222")
            ]
        )
    }

    /// Spec scenario "Labels after stop".
    @Test
    func testMarkdownUsesTheSavedTranscriptsLabels() throws {
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.transcript = labelledTranscript(firstLabel: "Speaker 2")

        rewriteTranscriptMarkdown(for: session)

        let contents = try String(contentsOf: markdownURL, encoding: .utf8)
        let header = MarkdownRenderer().header(for: session)
        #expect(contents == header + "\n**Speaker 2** [00:00 – 00:01]\none\n\n**Alice** [00:01 – 00:02]\ntwo\n")
    }

    /// Spec scenario "Rename rewrites the file".
    @Test @MainActor
    func testRenameRewritesTheMarkdown() throws {
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = labelledTranscript(firstLabel: "Speaker 2")
        session.transcript = transcript
        rewriteTranscriptMarkdown(for: session)

        _ = TranscriptDetailViewModel.renameSpeaker(id: "speaker_mic_0", to: "Bob", in: transcript, of: session)

        let contents = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(contents.contains("**Bob** [00:00 – 00:01]\none\n"))
        #expect(!contents.contains("Speaker 2"))
    }

    /// Spec scenario "Retranscript replaces the file": the shown pass is the retranscript.
    @Test
    func testMarkdownFollowsTheRetranscript() throws {
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.transcript = labelledTranscript(firstLabel: "Speaker 2")
        session.retranscript = Transcript(
            fullText: "again",
            segments: [TranscriptSegment(speakerId: "S1", text: "again", startTime: 0, endTime: 1)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#333333")]
        )

        rewriteTranscriptMarkdown(for: session)

        let contents = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(contents == MarkdownRenderer().header(for: session) + "\n**Speaker 1** [00:00 – 00:01]\nagain\n")
    }

    @Test
    func testMarkdownWithoutSavedTranscriptNamesTheSource() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        context.insert(session)
        context.insert(RecordingTranscriptSegment(
            speakerId: "speaker_app_3", text: "from the app", startTime: 0, endTime: 1, audioSource: .app, session: session
        ))
        try context.save()

        rewriteTranscriptMarkdown(for: session)

        let contents = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(contents == MarkdownRenderer().header(for: session) + "\n**App** [00:00 – 00:01]\nfrom the app\n")
    }

    /// Spec scenario "File matches export".
    @Test
    func testMarkdownEqualsExport() throws {
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.transcript = labelledTranscript(firstLabel: "Speaker 2")

        rewriteTranscriptMarkdown(for: session)

        let exported = MarkdownRenderer().renderMarkdown(session: session, transcript: try #require(session.transcript))
        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == exported)
    }

    /// Spec scenario "Session rename rewrites the file".
    @Test
    func testSessionRenameRewritesTheTitle() throws {
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.title = "Standup"
        session.transcript = labelledTranscript(firstLabel: "Speaker 2")
        rewriteTranscriptMarkdown(for: session)

        session.title = "Weekly sync"
        rewriteTranscriptMarkdown(for: session)

        let contents = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(contents.hasPrefix("# Weekly sync\n"))
    }

    // MARK: - One-time regeneration

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "transcript-md-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Spec scenario "Existing files are regenerated once".
    @Test
    func testRegenerationRewritesAnOldFileOnce() throws {
        let context = ModelContext(try makeContainer())
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.transcript = labelledTranscript(firstLabel: "Speaker 2")
        context.insert(session)
        try context.save()
        try "# Transcript\n\n[0.00-1.00] Speaker 2: one\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        let defaults = try isolatedDefaults()

        try TranscriptMarkdownRegeneration.regenerateIfNeeded(in: context, userDefaults: defaults)

        let exported = MarkdownRenderer().renderMarkdown(session: session, transcript: try #require(session.transcript))
        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == exported)
        #expect(defaults.integer(forKey: TranscriptMarkdownRegeneration.formatVersionKey)
            == TranscriptMarkdownRegeneration.currentFormatVersion)

        try "untouched".write(to: markdownURL, atomically: true, encoding: .utf8)
        try TranscriptMarkdownRegeneration.regenerateIfNeeded(in: context, userDefaults: defaults)
        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == "untouched")
    }

    @Test
    func testRegenerationSkipsARecordingInProgress() throws {
        let context = ModelContext(try makeContainer())
        let (session, directory, markdownURL) = try markdownSession()
        defer { try? FileManager.default.removeItem(at: directory) }
        session.status = .recording
        session.transcript = labelledTranscript(firstLabel: "Speaker 2")
        context.insert(session)
        try context.save()
        try "live".write(to: markdownURL, atomically: true, encoding: .utf8)

        try TranscriptMarkdownRegeneration.regenerateIfNeeded(in: context, userDefaults: try isolatedDefaults())

        #expect(try String(contentsOf: markdownURL, encoding: .utf8) == "live")
    }

    @Test
    func testRegenerationRetriesAfterAFailedWrite() throws {
        let context = ModelContext(try makeContainer())
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("mic.wav")
        let session = RecordingSession(createdAt: .now, duration: 10, micAudioURL: missingFolder.path, title: "T")
        session.transcript = labelledTranscript(firstLabel: "Speaker 2")
        context.insert(session)
        try context.save()
        let defaults = try isolatedDefaults()

        #expect(throws: (any Error).self) {
            try TranscriptMarkdownRegeneration.regenerateIfNeeded(in: context, userDefaults: defaults)
        }
        #expect(defaults.object(forKey: TranscriptMarkdownRegeneration.formatVersionKey) == nil)
    }
}
