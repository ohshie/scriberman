import AVFoundation
import Foundation

enum AudioDownmixer {
    static func toMono(channelSamples: [[Float]]) -> [Float] {
        guard !channelSamples.isEmpty else {
            return []
        }
        if channelSamples.count == 1 {
            return channelSamples[0]
        }

        let frameCount = channelSamples[0].count
        var mono = Array(repeating: Float(0), count: frameCount)
        let channelCount = Float(channelSamples.count)

        for channel in channelSamples {
            guard channel.count == frameCount else {
                continue
            }
            for index in 0..<frameCount {
                mono[index] += channel[index]
            }
        }

        for index in 0..<frameCount {
            mono[index] /= channelCount
        }
        return mono
    }

    static func toMono(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else {
            return []
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            return []
        }

        let stride = max(1, buffer.stride)
        if channelCount == 1 {
            return (0..<frameCount).map { frameIndex in
                channelData[0][frameIndex * stride]
            }
        }

        var mono = Array(repeating: Float(0), count: frameCount)
        for frame in 0..<frameCount {
            let sampleIndex = frame * stride
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][sampleIndex]
            }
            mono[frame] = sum / Float(channelCount)
        }
        return mono
    }
}
