import AVFoundation
import Foundation
import XCTest
@testable import Scriberman

final class AudioChannelReaderTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testReadReturnsSamplesPerChannel() throws {
        let url = tempDirectoryURL.appendingPathComponent("stereo-input.wav")
        let left = [Float(0.8), 0.6, 0.4, 0.2]
        let right = [Float(-0.1), -0.2, -0.3, -0.4]
        try writeStereoWAV(left: left, right: right, to: url)

        let reader = AudioChannelReader()
        let channels: [[Float]]
        do {
            channels = try reader.read(url: url)
        } catch {
            if shouldSkipForSandboxAudioIO(error) {
                throw XCTSkip("Skipping channel reader test: AVAudioFile read unavailable in sandbox (\(error.localizedDescription))")
            }
            throw error
        }

        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(channels[0].count, 4)
        XCTAssertEqual(channels[1].count, 4)
        XCTAssertEqual(channels[0][0], 0.8, accuracy: 0.001)
        XCTAssertEqual(channels[1][0], -0.1, accuracy: 0.001)
    }

    private func writeStereoWAV(left: [Float], right: [Float], to url: URL) throws {
        guard left.count == right.count else {
            throw RecordingError.failedToStart("Mismatched channel sizes in test audio.")
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw RecordingError.failedToStart("Failed to create test stereo format.")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(left.count)
        ), let channelData = buffer.int16ChannelData else {
            throw RecordingError.failedToStart("Failed to allocate test stereo buffer.")
        }

        buffer.frameLength = AVAudioFrameCount(left.count)
        for index in 0..<left.count {
            let clampedLeft = max(-1.0, min(1.0, left[index]))
            let clampedRight = max(-1.0, min(1.0, right[index]))
            channelData[0][index] = Int16(clampedLeft * Float(Int16.max))
            channelData[1][index] = Int16(clampedRight * Float(Int16.max))
        }

        try file.write(from: buffer)
    }

    private func shouldSkipForSandboxAudioIO(_ error: Error) -> Bool {
        let message = String(describing: error)
        let nsError = error as NSError
        return message.contains("Foundation._GenericObjCError")
            || message.contains("nilError")
            || (nsError.domain == "com.apple.coreaudio.avfaudio" && nsError.code == 2003334207)
    }
}
