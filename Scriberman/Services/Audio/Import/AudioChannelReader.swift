import AVFoundation
import Foundation

/// Decoded samples per channel, at the sample rate they were decoded at.
struct DecodedAudio: Equatable, Sendable {
    let channels: [[Float]]
    let sampleRate: Double
}

struct AudioChannelReader {
    func read(url: URL) throws -> DecodedAudio {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            file = try AVAudioFile(
                forReading: url,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }

        let inputFormat = file.processingFormat
        let channelCount = Int(inputFormat.channelCount)
        guard channelCount > 0 else {
            throw RecordingError.failedToStart("Import failed: invalid channel count.")
        }
        guard let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        ) else {
            throw RecordingError.failedToStart("Import failed: read format allocation failed.")
        }

        var samplesByChannel = Array(repeating: [Float](), count: channelCount)
        let frameCapacity: AVAudioFrameCount = 4_096

        // Bounded by the file's own length. `AVAudioFile.read(into:frameCount:)` throws at end of
        // file instead of returning an empty buffer, so waiting for a zero-length read discarded
        // every complete decode and sent each import down the fallback path.
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: frameCapacity) else {
                throw RecordingError.failedToStart("Import failed: buffer allocation failed.")
            }
            let remaining = file.length - file.framePosition
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(frameCapacity), remaining)))
            guard buffer.frameLength > 0 else {
                // Defensive: a short read with frames still outstanding would otherwise spin.
                break
            }
            guard let channelData = buffer.floatChannelData else {
                throw RecordingError.failedToStart("Import failed: missing channel data.")
            }

            let frameCount = Int(buffer.frameLength)
            for channelIndex in 0..<channelCount {
                let channelSamples = Array(UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount))
                samplesByChannel[channelIndex].append(contentsOf: channelSamples)
            }
        }

        return DecodedAudio(channels: samplesByChannel, sampleRate: inputFormat.sampleRate)
    }
}
