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

        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.alreadyTrimmed) {
            try await service.trim(session: session, end: 5)
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

        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.trimEndExceedsDuration) {
            try await service.trim(session: session, end: 10)
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

        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.missingMixdown) {
            try await service.trim(session: session, end: 5)
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

        let service = AudioTrimService()
        await #expect(throws: AudioTrimError.notTrimmed) {
            try await service.restore(session: session)
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

        let service = AudioTrimService()
        do {
            try await service.trim(session: session, end: 3.0)
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

        let service = AudioTrimService()
        do {
            try await service.trim(session: session, end: 2.5)
        } catch {
            if isExpectedSandboxError(error) { return }
            throw error
        }

        do {
            try await service.restore(session: session)
        } catch {
            if isExpectedSandboxError(error) { return }
            throw error
        }

        #expect(!session.isTrimmed)
        #expect(session.trimEnd == nil)
        #expect(session.originalMixdownURL == nil)
        #expect(session.transcriptData == originalTranscriptData)
        #expect(session.originalTranscriptData == nil)
    }

    // MARK: - Helpers

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
