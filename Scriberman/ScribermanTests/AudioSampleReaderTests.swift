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
