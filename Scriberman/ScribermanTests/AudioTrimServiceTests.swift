import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
final class AudioTrimServiceTests {
    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - filterSegments

    @Test
    func testFilterSegmentsKeepsSegmentsBeforeTrimEnd() {
        let segments = [
            TranscriptSegment(speakerId: "A", text: "Hello", startTime: 0, endTime: 5),
            TranscriptSegment(speakerId: "A", text: "World", startTime: 6, endTime: 10),
        ]
        let result = AudioTrimService.filterSegments(segments, trimEnd: 15)
        #expect(result.count == 2)
        #expect(result[0].text == "Hello")
        #expect(result[1].text == "World")
    }

    @Test
    func testFilterSegmentsRemovesSegmentsStartingAfterTrimEnd() {
        let segments = [
            TranscriptSegment(speakerId: "A", text: "Hello", startTime: 0, endTime: 5),
            TranscriptSegment(speakerId: "A", text: "World", startTime: 65, endTime: 70),
        ]
        let result = AudioTrimService.filterSegments(segments, trimEnd: 60)
        #expect(result.count == 1)
        #expect(result[0].text == "Hello")
    }

    @Test
    func testFilterSegmentsCapsBoundarySegmentEndTime() {
        let id = UUID()
        let segments = [
            TranscriptSegment(id: id, speakerId: "A", text: "Straddling", startTime: 55, endTime: 63),
        ]
        let result = AudioTrimService.filterSegments(segments, trimEnd: 60)
        #expect(result.count == 1)
        #expect(result[0].endTime == 60.0)
        #expect(result[0].text == "Straddling")
        #expect(result[0].id == id)
    }

    @Test
    func testFilterSegmentsEmptyInput() {
        let result = AudioTrimService.filterSegments([], trimEnd: 30)
        #expect(result.isEmpty)
    }

    @Test
    func testTrimmedTranscriptKeepsVoiceprintsAndProfileLinks() {
        let profileID = UUID()
        let transcript = Transcript(
            fullText: "Hello World",
            segments: [
                TranscriptSegment(speakerId: "A", text: "Hello", startTime: 0, endTime: 5),
                TranscriptSegment(speakerId: "A", text: "World", startTime: 65, endTime: 70),
            ],
            speakers: [TranscriptSpeaker(id: "A", label: "Speaker 1", colorHex: "#112233")],
            speakerEmbeddings: ["A": [0.5]],
            speakerProfileIDs: ["A": profileID],
            voiceprintSpace: VoiceprintSpace.current
        )

        let trimmed = AudioTrimService.trimmedTranscript(transcript, end: 60)

        #expect(trimmed.speakerEmbeddings == ["A": [0.5]])
        #expect(trimmed.speakerVoiceprints == ["A": [[0.5]]])
        #expect(trimmed.speakerProfileIDs == ["A": profileID])
        #expect(trimmed.voiceprintSpace == VoiceprintSpace.current)
        #expect(trimmed.segments.map(\.text) == ["Hello"])
        #expect(trimmed.fullText == "Hello")
    }

    // MARK: - Guard: already trimmed

    @Test
    func testTrimThrowsWhenAlreadyTrimmed() async throws {
        let mixdownURL = tempDir.appendingPathComponent("recording.m4a")
        FileManager.default.createFile(atPath: mixdownURL.path, contents: Data())

        let session = RecordingSession(
            duration: 10,
            micAudioURL: tempDir.appendingPathComponent("mic.wav").path,
            mixdownURL: mixdownURL.path,
            title: "Test"
        )
        session.originalMixdownURL = tempDir.appendingPathComponent("recording-original.m4a").path

        let context = try makeContext(inserting: session)
        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.alreadyTrimmed) {
            try await service.trim(session: session, end: 5, context: context)
        }
    }

    // MARK: - Guard: trimEnd >= duration

    @Test
    func testTrimThrowsWhenTrimEndExceedsDuration() async throws {
        let mixdownURL = tempDir.appendingPathComponent("recording.m4a")
        FileManager.default.createFile(atPath: mixdownURL.path, contents: Data())

        let session = RecordingSession(
            duration: 10,
            micAudioURL: tempDir.appendingPathComponent("mic.wav").path,
            mixdownURL: mixdownURL.path,
            title: "Test"
        )

        let context = try makeContext(inserting: session)
        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.trimEndExceedsDuration) {
            try await service.trim(session: session, end: 10, context: context)
        }
    }

    // MARK: - Guard: missing mixdown

    @Test
    func testTrimThrowsWhenMixdownURLMissing() async throws {
        let session = RecordingSession(
            duration: 10,
            micAudioURL: tempDir.appendingPathComponent("mic.wav").path,
            mixdownURL: nil,
            title: "Test"
        )

        let context = try makeContext(inserting: session)
        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.missingMixdown) {
            try await service.trim(session: session, end: 5, context: context)
        }
    }

    // MARK: - Guard: restore when not trimmed

    @Test
    func testRestoreThrowsWhenNotTrimmed() async throws {
        let session = RecordingSession(
            duration: 10,
            micAudioURL: tempDir.appendingPathComponent("mic.wav").path,
            mixdownURL: tempDir.appendingPathComponent("recording.m4a").path,
            title: "Test"
        )

        let context = try makeContext(inserting: session)
        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.notTrimmed) {
            try await service.restore(session: session, context: context)
        }
    }

    // MARK: - Transcript adjustment on trim (integration with real audio)

    @Test
    func testTrimAdjustsTranscriptAndBacksUpOriginals() async throws {
        let mixdownURL = tempDir.appendingPathComponent("recording.m4a")
        try makeShortM4A(at: mixdownURL, durationSeconds: 5)

        let session = RecordingSession(
            duration: 5,
            micAudioURL: tempDir.appendingPathComponent("mic.wav").path,
            mixdownURL: mixdownURL.path,
            title: "Test"
        )

        let transcript = Transcript(
            fullText: "Hello World",
            segments: [
                TranscriptSegment(speakerId: "A", text: "Hello", startTime: 0, endTime: 1.5),
                TranscriptSegment(speakerId: "A", text: "World", startTime: 2.0, endTime: 4.0),
                TranscriptSegment(speakerId: "A", text: "Late", startTime: 3.5, endTime: 5.5),
            ],
            speakers: [TranscriptSpeaker(id: "A", label: "Speaker A", colorHex: "#FF0000")]
        )
        session.transcript = transcript
        let originalTranscriptData = session.transcriptData

        let context = try makeContext(inserting: session)
        let service = AudioTrimService()
        do {
            try await service.trim(session: session, end: 3.0, context: context)
        } catch {
            if isExpectedSandboxError(error) { return }
            throw error
        }

        // Backup fields set
        #expect(session.isTrimmed)
        #expect(session.trimEnd == 3.0)
        #expect(session.originalTranscriptData == originalTranscriptData)
        #expect(session.originalMixdownURL != nil)

        // Transcript filtered
        let trimmedSegments = session.transcript?.segments ?? []
        #expect(trimmedSegments.count == 2)
        #expect(trimmedSegments[0].text == "Hello")
        #expect(trimmedSegments[1].text == "World")
        let lateSegment = trimmedSegments.first(where: { $0.text == "Late" })
        #expect(lateSegment == nil)

        // Backup file exists
        let originalPath = session.originalMixdownURL ?? ""
        #expect(FileManager.default.fileExists(atPath: originalPath))
    }

    @Test
    func testRestoreReturnsTrimmedSessionToOriginalState() async throws {
        let mixdownURL = tempDir.appendingPathComponent("recording.m4a")
        try makeShortM4A(at: mixdownURL, durationSeconds: 5)

        let session = RecordingSession(
            duration: 5,
            micAudioURL: tempDir.appendingPathComponent("mic.wav").path,
            mixdownURL: mixdownURL.path,
            title: "Test"
        )

        let transcript = Transcript(
            fullText: "Hello",
            segments: [
                TranscriptSegment(speakerId: "A", text: "Hello", startTime: 0, endTime: 2),
            ],
            speakers: []
        )
        session.transcript = transcript
        let originalTranscriptData = session.transcriptData

        let context = try makeContext(inserting: session)
        let service = AudioTrimService()
        do {
            try await service.trim(session: session, end: 2.5, context: context)
        } catch {
            if isExpectedSandboxError(error) { return }
            throw error
        }

        #expect(abs(try await duration(of: mixdownURL) - 2.5) < 0.1)

        do {
            try await service.restore(session: session, context: context)
        } catch {
            if isExpectedSandboxError(error) { return }
            throw error
        }

        #expect(abs(try await duration(of: mixdownURL) - 5) < 0.1)
        #expect(!session.isTrimmed)
        #expect(session.trimEnd == nil)
        #expect(session.originalMixdownURL == nil)
        #expect(session.transcriptData == originalTranscriptData)
        #expect(session.originalTranscriptData == nil)
    }

    // MARK: - Trim input validation

    @Test(arguments: [0, -1, Double.nan, Double.infinity, -Double.infinity])
    func testTrimRejectsNonFiniteOrNonPositiveEnd(end: Double) async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        let service = fixture.service()

        await #expect(throws: AudioTrimError.trimEndExceedsDuration) {
            try await service.trim(session: fixture.session, end: end, context: fixture.context)
        }
        try fixture.expectUntouched()
    }

    @Test
    func testTrimRejectsEndAtOrPastDurationWithoutTouchingFiles() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)

        await #expect(throws: AudioTrimError.trimEndExceedsDuration) {
            try await fixture.service().trim(session: fixture.session, end: fixture.session.duration, context: fixture.context)
        }
        try fixture.expectUntouched()
    }

    @Test
    func testTrimChecksSpaceForAudioPlusVideo() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        let audioSize = Int64(Fixture.audioContents.utf8.count)
        let service = fixture.service(capacity: audioSize + 1)

        await #expect(throws: AudioTrimError.insufficientDiskSpace) {
            try await service.trim(session: fixture.session, end: 60, context: fixture.context)
        }
        try fixture.expectUntouched()
    }

    @Test
    func testTrimSucceedsWhenSpaceCoversAudioPlusVideo() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        let required = Int64(Fixture.audioContents.utf8.count + Fixture.videoContents.utf8.count)

        try await fixture.service(capacity: required).trim(session: fixture.session, end: 60, context: fixture.context)

        #expect(fixture.session.isTrimmed)
    }

    @Test
    func testTrimRefusesToOverwriteALeftoverOriginal() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: false)
        try "LEFTOVER".write(to: fixture.originalMixdownURL, atomically: true, encoding: .utf8)

        await #expect(throws: AudioTrimError.alreadyTrimmed) {
            try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)
        }
        #expect(try fixture.contents(of: fixture.originalMixdownURL) == "LEFTOVER")
        #expect(try fixture.contents(of: fixture.mixdownURL) == Fixture.audioContents)
    }

    // MARK: - Trim transaction

    @Test
    func testTrimReplacesFilesAndKeepsOriginals() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)

        try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)

        #expect(try fixture.contents(of: fixture.mixdownURL) == Fixture.trimmed(Fixture.audioContents))
        #expect(try fixture.contents(of: fixture.screenURL) == Fixture.trimmed(Fixture.videoContents))
        #expect(try fixture.contents(of: fixture.originalMixdownURL) == Fixture.audioContents)
        #expect(try fixture.contents(of: fixture.originalScreenURL) == Fixture.videoContents)
        #expect(fixture.session.originalMixdownURL == fixture.originalMixdownURL.path)
        #expect(fixture.session.originalScreenVideoURL == fixture.originalScreenURL.path)
        #expect(fixture.session.trimEnd == 60)
        #expect(try fixture.tempFiles().isEmpty)
    }

    @Test
    func testFailingVideoExportLeavesEveryFileUntouched() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        let service = fixture.service(export: { source, destination, end in
            if source.pathExtension == "mov" { throw AudioTrimError.exportFailed("injected") }
            try await Fixture.fakeExport(source, destination, end)
        })

        await #expect(throws: AudioTrimError.exportFailed("injected")) {
            try await service.trim(session: fixture.session, end: 60, context: fixture.context)
        }
        try fixture.expectUntouched()
    }

    @Test
    func testFailingAudioReplaceLeavesEveryFileUntouched() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        let service = fixture.service(replaceItem: Fixture.replacing(failingOnCall: 1))

        await #expect(throws: CocoaError.self) {
            try await service.trim(session: fixture.session, end: 60, context: fixture.context)
        }
        try fixture.expectUntouched()
    }

    @Test
    func testFailingVideoReplaceRollsAudioBack() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        let service = fixture.service(replaceItem: Fixture.replacing(failingOnCall: 2))

        await #expect(throws: CocoaError.self) {
            try await service.trim(session: fixture.session, end: 60, context: fixture.context)
        }
        try fixture.expectUntouched()
    }

    @Test
    func testFailingSaveRollsTrimBack() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        let service = fixture.service(saveContext: { _ in throw CocoaError(.fileWriteUnknown) })

        await #expect(throws: CocoaError.self) {
            try await service.trim(session: fixture.session, end: 60, context: fixture.context)
        }
        try fixture.expectUntouched()
    }

    // MARK: - Restore transaction

    @Test(arguments: [1, 2])
    func testFailingRestoreSwapKeepsSessionTrimmedAndBothVersions(failingCall: Int) async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)
        let service = fixture.service(replaceItem: Fixture.replacing(failingOnCall: failingCall))

        await #expect(throws: CocoaError.self) {
            try await service.restore(session: fixture.session, context: fixture.context)
        }
        try fixture.expectStillTrimmed()

        try await fixture.service().restore(session: fixture.session, context: fixture.context)
        #expect(!fixture.session.isTrimmed)
    }

    @Test
    func testFailingRestoreSaveKeepsSessionTrimmedAndBothVersions() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)
        let service = fixture.service(saveContext: { _ in throw CocoaError(.fileWriteUnknown) })

        await #expect(throws: CocoaError.self) {
            try await service.restore(session: fixture.session, context: fixture.context)
        }
        try fixture.expectStillTrimmed()
    }

    @Test
    func testRestoreLeavesNoOriginalOrTempFiles() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: true)
        try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)

        try await fixture.service().restore(session: fixture.session, context: fixture.context)

        let names = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        #expect(names.filter { $0.contains("-original") }.isEmpty)
        #expect(try fixture.tempFiles().isEmpty)
        #expect(try fixture.contents(of: fixture.mixdownURL) == Fixture.audioContents)
        #expect(try fixture.contents(of: fixture.screenURL) == Fixture.videoContents)
        #expect(fixture.session.originalScreenVideoURL == nil)
    }

    // MARK: - Transcript consistency

    @Test
    func testTrimRebuildsFullTextOfBothTranscripts() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: false)

        try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)

        #expect(fixture.session.transcript?.fullText == "kept words straddling words")
        #expect(fixture.session.retranscript?.fullText == "kept words straddling words")
        #expect(fixture.session.transcript?.fullText.contains(Fixture.removedPhrase) == false)
    }

    @Test
    func testTranscriptMarkdownFollowsTrimAndRestore() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: false)

        try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)
        let trimmedMarkdown = try fixture.contents(of: fixture.markdownURL)
        #expect(!trimmedMarkdown.contains(Fixture.removedPhrase))
        #expect(trimmedMarkdown.contains("[55.00-60.00] S1: straddling words"))

        try await fixture.service().restore(session: fixture.session, context: fixture.context)
        let restoredMarkdown = try fixture.contents(of: fixture.markdownURL)
        #expect(restoredMarkdown.contains(Fixture.removedPhrase))
        #expect(restoredMarkdown.contains("[55.00-63.00] S1: straddling words"))
    }

    @Test
    func testSearchAndTransformationInputFollowTrimAndRestore() async throws {
        let fixture = try Fixture(tempDir: tempDir, withVideo: false)
        let item = JobsViewModel.SessionListItem.recording(fixture.session)
        let detail = TranscriptDetailViewModel(session: fixture.session, aiProviderService: makeAIProviderService())
        #expect(JobsViewModel.matches(query: Fixture.removedPhrase, item: item) == .transcript)
        #expect(detail.finalTranscriptText.contains(Fixture.removedPhrase))

        try await fixture.service().trim(session: fixture.session, end: 60, context: fixture.context)
        #expect(JobsViewModel.matches(query: Fixture.removedPhrase, item: item) == nil)
        #expect(!detail.finalTranscriptText.contains(Fixture.removedPhrase))

        try await fixture.service().restore(session: fixture.session, context: fixture.context)
        #expect(JobsViewModel.matches(query: Fixture.removedPhrase, item: item) == .transcript)
        #expect(detail.finalTranscriptText.contains(Fixture.removedPhrase))
    }

    // MARK: - Helpers

    private func makeContext(inserting session: RecordingSession) throws -> ModelContext {
        let context = ModelContext(try Fixture.makeContainer())
        context.insert(session)
        return context
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    private func makeAIProviderService() -> AIProviderService {
        let defaults = UserDefaults(suiteName: "AudioTrimServiceTests.\(UUID().uuidString)") ?? .standard
        return AIProviderService(keychainStore: MockKeychainStore(), store: AIProviderStore(defaults: defaults))
    }

    private func makeShortM4A(at url: URL, durationSeconds: Double) throws {
        let sampleRate = 44100.0
        let sampleCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = sampleCount

        let m4aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ]
        let file = try AVAudioFile(forWriting: url, settings: m4aSettings)
        try file.write(from: buffer)
    }

    private func isExpectedSandboxError(_ error: Error) -> Bool {
        let desc = error.localizedDescription.lowercased()
        return desc.contains("sandbox") || desc.contains("permission") || desc.contains("operation not permitted")
    }
}

/// A trimmable session on disk with text files standing in for media, so each step of the trim and
/// restore transactions can be failed on purpose and the files compared byte for byte.
@MainActor
private struct Fixture {
    static let audioContents = "AUDIO"
    static let videoContents = "VIDEO"
    static let removedPhrase = "phrase after the cut"

    let session: RecordingSession
    let context: ModelContext
    let folder: URL
    let mixdownURL: URL
    let screenURL: URL
    let originalMixdownURL: URL
    let originalScreenURL: URL
    let markdownURL: URL
    private let transcriptData: Data?
    private let retranscriptData: Data?

    init(tempDir: URL, withVideo: Bool) throws {
        folder = tempDir
        mixdownURL = tempDir.appendingPathComponent("recording.m4a")
        screenURL = tempDir.appendingPathComponent("screen.mov")
        originalMixdownURL = tempDir.appendingPathComponent("recording-original.m4a")
        originalScreenURL = tempDir.appendingPathComponent("screen-original.mov")
        markdownURL = tempDir.appendingPathComponent("transcript.md")
        try Self.audioContents.write(to: mixdownURL, atomically: true, encoding: .utf8)
        if withVideo {
            try Self.videoContents.write(to: screenURL, atomically: true, encoding: .utf8)
        }

        session = RecordingSession(
            duration: 120,
            micAudioURL: tempDir.appendingPathComponent("mic.wav").path,
            screenVideoURL: withVideo ? screenURL.path : nil,
            mixdownURL: mixdownURL.path,
            title: "Trim fixture"
        )
        context = ModelContext(try Self.makeContainer())
        context.insert(session)

        let segments = [
            TranscriptSegment(speakerId: "S1", text: "kept words", startTime: 10, endTime: 20),
            TranscriptSegment(speakerId: "S1", text: "straddling words", startTime: 55, endTime: 63),
            TranscriptSegment(speakerId: "S1", text: Self.removedPhrase, startTime: 65, endTime: 70),
        ]
        let transcript = Transcript(fullText: Transcript.fullText(joining: segments), segments: segments, speakers: [])
        session.transcript = transcript
        session.retranscript = transcript
        for (index, segment) in segments.enumerated() {
            context.insert(RecordingTranscriptSegment(
                segment: segment,
                createdAt: Date(timeIntervalSince1970: Double(index)),
                session: session
            ))
        }
        try context.save()
        rewriteTranscriptMarkdown(for: session)

        transcriptData = session.transcriptData
        retranscriptData = session.retranscriptData
    }

    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    static func trimmed(_ contents: String) -> String { "TRIMMED:" + contents }

    static let fakeExport: AudioTrimService.Export = { source, destination, _ in
        let contents = try String(contentsOf: source, encoding: .utf8)
        try trimmed(contents).write(to: destination, atomically: true, encoding: .utf8)
    }

    /// The real `replaceItemAt` swap, except that call number `failingCall` throws without
    /// touching anything.
    static func replacing(failingOnCall failingCall: Int) -> AudioTrimService.ReplaceItem {
        var calls = 0
        return { original, replacement, backupName in
            calls += 1
            if calls == failingCall { throw CocoaError(.fileWriteUnknown) }
            _ = try FileManager.default.replaceItemAt(
                original,
                withItemAt: replacement,
                backupItemName: backupName,
                options: backupName == nil ? [] : .withoutDeletingBackupItem
            )
        }
    }

    func service(
        capacity: Int64 = .max,
        export: AudioTrimService.Export? = nil,
        replaceItem: AudioTrimService.ReplaceItem? = nil,
        saveContext: AudioTrimService.SaveContext? = nil
    ) -> AudioTrimService {
        AudioTrimService(
            capacityProvider: { _ in capacity },
            export: export ?? Self.fakeExport,
            replaceItem: replaceItem,
            saveContext: saveContext
        )
    }

    func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func tempFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("_trim_temp_") }
    }

    /// Every file is the pre-trim file, no backup or temp file exists, and the session is as it was.
    func expectUntouched() throws {
        #expect(try contents(of: mixdownURL) == Self.audioContents)
        if session.screenVideoURL != nil {
            #expect(try contents(of: screenURL) == Self.videoContents)
        }
        #expect(!FileManager.default.fileExists(atPath: originalMixdownURL.path))
        #expect(!FileManager.default.fileExists(atPath: originalScreenURL.path))
        #expect(try tempFiles().isEmpty)
        #expect(!session.isTrimmed)
        #expect(session.trimEnd == nil)
        #expect(session.originalScreenVideoURL == nil)
        #expect(session.originalTranscriptData == nil)
        #expect(session.originalRetranscriptData == nil)
        #expect(session.transcriptData == transcriptData)
        #expect(session.retranscriptData == retranscriptData)
    }

    /// The session is still marked trimmed, and both versions of every file are where a retried
    /// restore expects them.
    func expectStillTrimmed() throws {
        #expect(session.isTrimmed)
        #expect(session.trimEnd == 60)
        #expect(session.originalScreenVideoURL == originalScreenURL.path)
        #expect(session.originalTranscriptData == transcriptData)
        #expect(session.transcript?.fullText.contains(Self.removedPhrase) == false)
        #expect(try contents(of: mixdownURL) == Self.trimmed(Self.audioContents))
        #expect(try contents(of: originalMixdownURL) == Self.audioContents)
        #expect(try contents(of: screenURL) == Self.trimmed(Self.videoContents))
        #expect(try contents(of: originalScreenURL) == Self.videoContents)
        #expect(try tempFiles().isEmpty)
    }
}
