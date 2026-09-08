import AVFoundation
import Foundation
import Testing
@testable import Scriberman

final class AudioSampleReaderTests {
    private final class LockedInt: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func incrementAndGet() -> Int {
            lock.lock()
            value += 1
            let current = value
            lock.unlock()
            return current
        }

        func get() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: - Real-file reads through the primary path

    /// Writes a file exactly as `AudioFileStreamer.prepare` does: float32, non-interleaved,
    /// 48 kHz mono.
    private func writeCaptureFile(frames: Int) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic.wav")
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        var written = 0
        while written < frames {
            let chunk = min(960, frames - written)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))
            )
            buffer.frameLength = AVAudioFrameCount(chunk)
            let data = try #require(buffer.floatChannelData)[0]
            for index in 0..<chunk {
                data[index] = sinf(Float(written + index) * 0.05) * 0.5
            }
            try file.write(from: buffer)
            written += chunk
        }
        if #available(macOS 15.0, *) { file.close() }
        return url
    }

    /// Reaching the end of a file must not be a failure. `AVAudioFile.read(into:frameCount:)`
    /// throws at end of file rather than returning an empty buffer, so a loop waiting for a
    /// zero-length buffer read every frame correctly and then threw the decode away.
    @Test
    func testCompleteFileIsReadThroughThePrimaryPath() async throws {
        let url = try writeCaptureFile(frames: 48_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let extCalls = LockedInt()

        let reader = AudioSampleReader(
            extAudioFileRead: { _, _ in
                _ = extCalls.incrementAndGet()
                return []
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "mic")

        #expect(samples.count == 48_000)
        #expect(extCalls.get() == 0)
    }

    /// A file whose length is not a whole number of read chunks must still read completely, since
    /// the final partial chunk is where the off-by-one at end of file showed up.
    @Test
    func testFileEndingMidChunkIsReadCompletely() async throws {
        // 4096 is the reader's chunk size; 10_000 leaves a 1808-frame remainder.
        let url = try writeCaptureFile(frames: 10_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let extCalls = LockedInt()

        let reader = AudioSampleReader(
            extAudioFileRead: { _, _ in
                _ = extCalls.incrementAndGet()
                return []
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "mic")

        #expect(samples.count == 10_000)
        #expect(extCalls.get() == 0)
    }

    /// An empty capture file is not an error and must not reach the fallback.
    @Test
    func testEmptyFileReadsAsNoSamplesWithoutFallback() async throws {
        let url = try writeCaptureFile(frames: 0)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let extCalls = LockedInt()

        let reader = AudioSampleReader(
            extAudioFileRead: { _, _ in
                _ = extCalls.incrementAndGet()
                return []
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "mic")

        #expect(samples.isEmpty)
        #expect(extCalls.get() == 0)
    }

    /// The fallback stays, reserved for files that genuinely cannot be decoded.
    @Test
    func testUndecodableFileStillFallsBack() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garbage.wav")
        try Data(repeating: 0x41, count: 512).write(to: url)

        let extCalls = LockedInt()
        let reader = AudioSampleReader(
            extAudioFileRead: { _, _ in
                _ = extCalls.incrementAndGet()
                return [0.25]
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "mic")

        #expect(samples == [0.25])
        #expect(extCalls.get() == 1)
    }

    @Test
    func testReadFallsBackToExtAudioFilePath() async throws {
        let url = URL(fileURLWithPath: "/tmp/mock-audio.wav")
        let avCalls = LockedInt()
        let extCalls = LockedInt()

        let reader = AudioSampleReader(
            avAudioFileRead: { _ in
                _ = avCalls.incrementAndGet()
                throw TestError.avFailure
            },
            extAudioFileRead: { _, _ in
                _ = extCalls.incrementAndGet()
                return [0.1, -0.1, 0.2]
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "mic")

        #expect(samples == [0.1, -0.1, 0.2])
        #expect(avCalls.get() == 1)
        #expect(extCalls.get() == 1)
    }

    @Test
    func testReadRetriesUntilSuccess() async throws {
        let url = URL(fileURLWithPath: "/tmp/mock-audio-retry.wav")
        let fallbackAttempts = LockedInt()

        let reader = AudioSampleReader(
            avAudioFileRead: { _ in
                throw TestError.avFailure
            },
            extAudioFileRead: { _, _ in
                let attempts = fallbackAttempts.incrementAndGet()
                if attempts < 3 {
                    throw TestError.transientFailure
                }
                return [0.5]
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "app")

        #expect(samples == [0.5])
        #expect(fallbackAttempts.get() == 3)
    }

    @Test
    func testReadThrowsAfterMaxRetries() async {
        let url = URL(fileURLWithPath: "/tmp/mock-audio-fail.wav")

        let reader = AudioSampleReader(
            avAudioFileRead: { _ in
                throw TestError.avFailure
            },
            extAudioFileRead: { _, _ in
                throw NSError(domain: "AudioSampleReaderTests", code: 77, userInfo: [NSLocalizedDescriptionKey: "forced failure"])
            },
            sleep: { _ in }
        )

        do {
            _ = try await reader.read(from: url, label: "mic")
            Issue.record("Expected read to fail after retries")
            return
        } catch {
            let description = error.localizedDescription
            #expect(description.contains("forced failure"), "Unexpected error description: \(description)")
        }
    }

    private enum TestError: Error {
        case avFailure
        case transientFailure
    }
}
