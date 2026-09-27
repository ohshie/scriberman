import AVFoundation
import Foundation
import Testing

/// Whether this test process can write audio files and read them back.
///
/// Audio integration tests declare this as a prerequisite with `.enabled(if:)`, so an environment
/// without audio file I/O reports them as skipped. Inside an environment that has it, any decode or
/// export error is a real failure: the tests no longer match on error text, because a reader
/// regression produces the same text as a sandbox that cannot do audio I/O.
enum AudioIOAvailability {
    static let isAvailable: Bool = probe()

    static let unavailableReason: Comment = "Audio file I/O is unavailable in this environment"

    private static func probe() -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-io-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let wavURL = directory.appendingPathComponent("probe.wav")
            let m4aURL = directory.appendingPathComponent("probe.m4a")
            try writeProbe(to: wavURL, settings: nil)
            try writeProbe(to: m4aURL, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: probeSampleRate,
                AVNumberOfChannelsKey: 1
            ])
            return try readFrameCount(from: wavURL) == probeFrameCount
                && readFrameCount(from: m4aURL) > 0
        } catch {
            return false
        }
    }

    private static let probeSampleRate: Double = 48_000
    private static let probeFrameCount = 4_800

    private static func writeProbe(to url: URL, settings: [String: Any]?) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: probeSampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(probeFrameCount)
        ), let channelData = buffer.floatChannelData else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(probeFrameCount)
        channelData[0].initialize(repeating: 0.1, count: probeFrameCount)

        // The file is finalized when it goes out of scope, before it is read back.
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings ?? format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private static func readFrameCount(from url: URL) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        try file.read(into: buffer)
        return Int(buffer.frameLength)
    }
}
