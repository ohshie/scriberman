import Foundation
import XCTest
@testable import Scriberman

final class AudioSampleReaderTests: XCTestCase {
    func testReadFallsBackToExtAudioFilePath() async throws {
        let url = URL(fileURLWithPath: "/tmp/mock-audio.wav")
        var avCalls = 0
        var extCalls = 0

        let reader = AudioSampleReader(
            avAudioFileRead: { _ in
                avCalls += 1
                throw TestError.avFailure
            },
            extAudioFileRead: { _, _ in
                extCalls += 1
                return [0.1, -0.1, 0.2]
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "mic")

        XCTAssertEqual(samples, [0.1, -0.1, 0.2])
        XCTAssertEqual(avCalls, 1)
        XCTAssertEqual(extCalls, 1)
    }

    func testReadRetriesUntilSuccess() async throws {
        let url = URL(fileURLWithPath: "/tmp/mock-audio-retry.wav")
        var fallbackAttempts = 0

        let reader = AudioSampleReader(
            avAudioFileRead: { _ in
                throw TestError.avFailure
            },
            extAudioFileRead: { _, _ in
                fallbackAttempts += 1
                if fallbackAttempts < 3 {
                    throw TestError.transientFailure
                }
                return [0.5]
            },
            sleep: { _ in }
        )

        let samples = try await reader.read(from: url, label: "app")

        XCTAssertEqual(samples, [0.5])
        XCTAssertEqual(fallbackAttempts, 3)
    }

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
            XCTFail("Expected read to fail after retries")
        } catch {
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("forced failure"), "Unexpected error description: \(description)")
        }
    }

    private enum TestError: Error {
        case avFailure
        case transientFailure
    }
}
