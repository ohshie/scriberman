import AVFoundation
import Foundation

struct AudioChannelReader {
    func read(url: URL) throws -> [[Float]] {
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

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: frameCapacity) else {
                throw RecordingError.failedToStart("Import failed: buffer allocation failed.")
            }
            try file.read(into: buffer, frameCount: frameCapacity)
            guard buffer.frameLength > 0 else {
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

        return samplesByChannel
    }
}
