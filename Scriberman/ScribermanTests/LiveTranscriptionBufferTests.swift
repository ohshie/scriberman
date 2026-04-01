import Foundation
import XCTest
@testable import Scriberman

final class LiveTranscriptionBufferTests: XCTestCase {
    func testAppendBelowThresholdStoresRemainderOnly() async {
        let buffer = LiveTranscriptionBuffer(chunkSampleCount: 4, sampleRate: 16_000)

        let chunk = await buffer.append(samples: [0.1, 0.2], source: .mic)

        XCTAssertNil(chunk)
        let remaining = await buffer.remainingBuffers()
        XCTAssertEqual(remaining[.mic] ?? [], [0.1, 0.2])
    }

    func testAppendAtThresholdReturnsChunkAndClearsBuffer() async {
        let buffer = LiveTranscriptionBuffer(chunkSampleCount: 4, sampleRate: 16_000)

        _ = await buffer.append(samples: [0.1, 0.2], source: .mic)
        let chunk = await buffer.append(samples: [0.3, 0.4], source: .mic)

        XCTAssertEqual(chunk ?? [], [0.1, 0.2, 0.3, 0.4])
        let offset = await buffer.takePendingChunkOffset(for: .mic)
        XCTAssertNotNil(offset)
        XCTAssertEqual(offset ?? -1, 0, accuracy: 0.0001)

        let remaining = await buffer.remainingBuffers()
        XCTAssertTrue((remaining[.mic] ?? []).isEmpty)
    }

    func testSecondChunkOffsetAdvancesByProcessedSamples() async {
        let buffer = LiveTranscriptionBuffer(chunkSampleCount: 4, sampleRate: 4)

        _ = await buffer.append(samples: [1, 1, 1, 1], source: .mic)
        _ = await buffer.takePendingChunkOffset(for: .mic)

        _ = await buffer.append(samples: [2, 2, 2, 2], source: .mic)
        let secondOffset = await buffer.takePendingChunkOffset(for: .mic)

        XCTAssertNotNil(secondOffset)
        XCTAssertEqual(secondOffset ?? -1, 1.0, accuracy: 0.0001)
    }

    func testResetClearsRemaindersAndOffsets() async {
        let buffer = LiveTranscriptionBuffer(chunkSampleCount: 4, sampleRate: 16_000)

        _ = await buffer.append(samples: [0.1, 0.2], source: .app)
        await buffer.reset()

        let remaining = await buffer.remainingBuffers()
        XCTAssertTrue(remaining.isEmpty)

        let pending = await buffer.takePendingChunkOffset(for: .app)
        XCTAssertNil(pending)
        let currentOffset = await buffer.currentOffset(for: .app)
        XCTAssertEqual(currentOffset, 0, accuracy: 0.0001)
    }
}
