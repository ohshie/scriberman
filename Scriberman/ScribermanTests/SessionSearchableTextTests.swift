import Foundation
import Testing
@testable import Scriberman

/// The stored searchable text follows the transcript pass the app displays, and stays current
/// through every writer — including the trim restore, which used to assign the blobs directly.
@MainActor
final class SessionSearchableTextTests {
    private func transcript(_ text: String) -> Transcript {
        Transcript(
            fullText: text,
            segments: [TranscriptSegment(speakerId: "A", text: text, startTime: 0, endTime: 1)],
            speakers: []
        )
    }

    private func makeRecording() -> RecordingSession {
        RecordingSession(duration: 1, micAudioURL: "/tmp/mic.wav", title: "Untitled")
    }

    private func makeImport() -> ImportedSession {
        ImportedSession(
            duration: 1,
            title: "Untitled",
            originalFileName: "clip.mp3",
            originalFormat: "mp3"
        )
    }

    // MARK: - RecordingSession

    @Test
    func testNewSessionHasNoSearchableText() {
        #expect(makeRecording().searchableText == nil)
    }

    @Test
    func testSettingTranscriptPopulatesSearchableText() {
        let session = makeRecording()
        session.transcript = transcript("the migration is next week")
        #expect(session.searchableText == "the migration is next week")
    }

    @Test
    func testClearingTranscriptRemovesSearchableText() {
        let session = makeRecording()
        session.transcript = transcript("the migration is next week")
        session.transcript = nil
        #expect(session.searchableText == nil)
    }

    @Test
    func testRetranscriptionReplacesSearchableText() {
        let session = makeRecording()
        session.transcript = transcript("first pass")
        session.retranscript = transcript("second pass")
        #expect(session.searchableText == "second pass")
    }

    @Test
    func testClearingRetranscriptFallsBackToTranscript() {
        let session = makeRecording()
        session.transcript = transcript("first pass")
        session.retranscript = transcript("second pass")
        session.retranscript = nil
        #expect(session.searchableText == "first pass")
    }

    @Test
    func testSearchableTextFollowsTheDisplayedPass() {
        let session = makeRecording()
        session.transcript = transcript("first pass")
        session.retranscript = transcript("second pass")

        // The same choice `displayedTranscript` makes: the retranscript wins when present.
        #expect(session.searchableText == (session.retranscript ?? session.transcript)?.fullText)
    }

    @Test
    func testInitialiserWithTranscriptDataPopulatesSearchableText() throws {
        let data = try JSONEncoder().encode(transcript("imported with a transcript"))
        let session = RecordingSession(
            duration: 1,
            micAudioURL: "/tmp/mic.wav",
            title: "Untitled",
            transcriptData: data
        )
        #expect(session.searchableText == "imported with a transcript")
    }

    // MARK: - ImportedSession

    @Test
    func testImportedSessionTranscriptPopulatesSearchableText() {
        let session = makeImport()
        session.transcript = transcript("imported audio")
        #expect(session.searchableText == "imported audio")
    }

    @Test
    func testImportedSessionRetranscriptionReplacesSearchableText() {
        let session = makeImport()
        session.transcript = transcript("first pass")
        session.retranscript = transcript("second pass")
        #expect(session.searchableText == "second pass")
    }

    // MARK: - Restore

    @Test
    func testRestoringTranscriptsRefreshesSearchableText() {
        let session = makeRecording()
        session.transcript = transcript("the original recording")
        let originalTranscriptData = session.transcriptData

        session.transcript = transcript("a later, shorter transcript")
        #expect(session.searchableText == "a later, shorter transcript")

        session.restoreTranscripts(transcriptData: originalTranscriptData, retranscriptData: nil)
        #expect(session.searchableText == "the original recording")
        #expect(session.transcriptData == originalTranscriptData)
    }

    @Test
    func testRestoringTranscriptsKeepsBlobsByteForByte() {
        let session = makeRecording()
        session.transcript = transcript("byte for byte")
        let blob = session.transcriptData

        session.transcript = nil
        session.restoreTranscripts(transcriptData: blob, retranscriptData: nil)

        // A restore assigns the stored blob rather than decoding and re-encoding it: a blob that
        // failed to decode would otherwise be silently replaced by nil.
        #expect(session.transcriptData == blob)
    }

    // MARK: - The rule the compiler cannot enforce

    /// Every file outside `Domain/` that touches a transcript, checked for a direct assignment to
    /// the encoded blobs. Assigning them outside the model layer skips the searchable-text refresh,
    /// which nothing in the compiler catches.
    @Test
    func testNoTranscriptBlobIsAssignedOutsideTheModelLayer() throws {
        let writers = [
            "../UI/TranscriptStudyView.swift",
            "../ViewModels/NewSessionViewModel.swift",
            "../ViewModels/JobsViewModel.swift",
            "../Services/Transcription/RetranscriptionService.swift",
            "../Services/Audio/Trim/AudioTrimService.swift",
        ]

        // The pattern requires a lowercase property name after the dot, so the trim backups —
        // `.originalTranscriptData`, `.originalRetranscriptData` — do not match.
        let assignment = try Regex(#"\.(?:transcriptData|retranscriptData)\s*="#)

        for relativePath in writers {
            let source = try readSourceFile(relativePathFromTests: relativePath)
            let offenders = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.firstMatch(of: assignment) != nil }
            #expect(offenders.isEmpty, "\(relativePath): \(offenders)")
        }
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent(relativePathFromTests)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
