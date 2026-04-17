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
}
