import AVFoundation

/// A thread-safe helper for writing audio buffers to a file and tracking peak levels.
/// @unchecked Sendable: mutable state is synchronized via stateLock and the internal serial queue.
final class AudioFileStreamer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.scriberman.audio-file-streamer", qos: .userInitiated)
    private let stateLock = NSLock()
    
    // Internal state protected by stateLock or queue
    private var _audioFile: AVAudioFile?
    private var _currentLevel: Float = 0
    
    /// The most recent peak audio level (0.0 to 1.0).
    var audioLevel: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentLevel
    }

    /// Initializes a new streamer.
    init() {}

    /// Prepares the streamer for writing to a specific URL with the given format.
    /// This method is synchronous on the internal queue to ensure any previous file is closed.
    func prepare(url: URL, format: AVAudioFormat) throws {
        try queue.sync {
            // Ensure any existing file is closed before opening a new one
            if #available(macOS 15.0, *) {
                _audioFile?.close()
            }
            
            _audioFile = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            
            stateLock.lock()
            _currentLevel = 0
            stateLock.unlock()
        }
    }

    /// Writes a buffer to the audio file asynchronously.
    /// Peak level is calculated synchronously before the async write to ensure UI updates are responsive.
    func write(buffer: AVAudioPCMBuffer) {
        let level = computeLevel(from: buffer)
        
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self._audioFile?.write(from: buffer)
                
                self.stateLock.lock()
                self._currentLevel = level
                self.stateLock.unlock()
            } catch {
                // In a production app, we might want to propagate this error back to a delegate
                // for now we just fail silently to avoid crashing the background tap
            }
        }
    }

    /// Closes the audio file.
    func close() {
        queue.sync {
            if #available(macOS 15.0, *) {
                _audioFile?.close()
            }
            _audioFile = nil
            
            stateLock.lock()
            _currentLevel = 0
            stateLock.unlock()
        }
    }

    private func computeLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return 0
        }

        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for sampleIndex in 0..<frameCount {
                let sample = samples[sampleIndex]
                sumSquares += sample * sample
            }
        }

        let meanSquare = sumSquares / Float(frameCount * max(channelCount, 1))
        let rms = sqrt(meanSquare)
        return min(max(rms, 0), 1)
    }
}
