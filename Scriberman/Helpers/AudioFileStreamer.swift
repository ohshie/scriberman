@preconcurrency import AVFoundation
import OSLog

/// A thread-safe helper for writing audio buffers to a file and tracking peak levels.
/// @unchecked Sendable: mutable state is synchronized via stateLock and the internal serial queue.
final class AudioFileStreamer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.scriberman.audio-file-streamer", qos: .userInitiated)
    private let stateLock = NSLock()
    private let logger = Logger(subsystem: "Scriberman", category: "AudioFileStreamer")
    private let label: String

    // Internal state protected by stateLock or queue
    private var _audioFile: AVAudioFile?
    private var _currentLevel: Float = 0
    private var _framesWritten: Int64 = 0
    private var _writeFailureCount: Int = 0
    private var _url: URL?
    private var _sampleRate: Double = 0
    private var _segments: [AudioCaptureSegment] = []

    /// The most recent peak audio level (0.0 to 1.0).
    var audioLevel: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentLevel
    }

    /// Total frames successfully written since the last `prepare` (diagnostics).
    var framesWritten: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _framesWritten
    }

    /// Number of write failures observed since the last `prepare` (diagnostics).
    var writeFailureCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _writeFailureCount
    }

    /// Initializes a new streamer. `label` tags diagnostics (e.g. "mic", "app").
    init(label: String = "audio") {
        self.label = label
    }

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
            _framesWritten = 0
            _writeFailureCount = 0
            _url = url
            _sampleRate = format.sampleRate
            _segments = []
            stateLock.unlock()
        }
    }

    /// Writes a buffer to the audio file asynchronously.
    /// Peak level is calculated synchronously before the async write to ensure UI updates are responsive.
    ///
    /// - Parameter hostTimeNanos: presentation host time (nanoseconds) of the buffer's first
    ///   frame. When provided, a timing segment is recorded so the file can be re-placed onto a
    ///   real-time timeline at mixdown (see `SynchronizedAudioTimeline`).
    func write(buffer: AVAudioPCMBuffer, hostTimeNanos: UInt64? = nil) {
        let level = computeLevel(from: buffer)

        let frameLength = Int64(buffer.frameLength)
        if let hostTimeNanos {
            stateLock.lock()
            _segments.append(AudioCaptureSegment(startHostTimeNanos: hostTimeNanos, frameCount: Int(frameLength)))
            stateLock.unlock()
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self._audioFile?.write(from: buffer)

                self.stateLock.lock()
                self._currentLevel = level
                self._framesWritten += frameLength
                self.stateLock.unlock()
            } catch {
                // Surface the failure so alignment problems are diagnosable rather than
                // silent (a dropped write shifts one channel permanently). We still avoid
                // crashing the realtime capture callback.
                self.stateLock.lock()
                self._writeFailureCount += 1
                let failureCount = self._writeFailureCount
                self.stateLock.unlock()
                self.logger.error(
                    "Audio write failed (\(self.label, privacy: .public), failure #\(failureCount, privacy: .public)): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Closes the audio file and, if timing segments were recorded, writes a `.timing`
    /// sidecar next to the audio file for timeline-anchored mixdown.
    func close() {
        queue.sync {
            if #available(macOS 15.0, *) {
                _audioFile?.close()
            }
            _audioFile = nil

            stateLock.lock()
            _currentLevel = 0
            let url = _url
            let sampleRate = _sampleRate
            let segments = _segments
            stateLock.unlock()

            if let url, !segments.isEmpty {
                writeTimingSidecar(for: url, sampleRate: sampleRate, segments: segments)
            }
        }
    }

    private func writeTimingSidecar(for audioURL: URL, sampleRate: Double, segments: [AudioCaptureSegment]) {
        let sidecar = CaptureTimingSidecar(sampleRate: sampleRate, segments: segments)
        let sidecarURL = Self.timingSidecarURL(for: audioURL)
        do {
            let data = try JSONEncoder().encode(sidecar)
            try data.write(to: sidecarURL, options: .atomic)
            logger.notice(
                "Wrote timing sidecar (\(self.label, privacy: .public)): segments=\(segments.count, privacy: .public) frames=\(sidecar.totalFrames, privacy: .public)"
            )
        } catch {
            logger.error("Failed to write timing sidecar (\(self.label, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The `.timing` sidecar location for a capture audio file.
    static func timingSidecarURL(for audioURL: URL) -> URL {
        audioURL.appendingPathExtension("timing")
    }

    /// Loads a timing sidecar if present.
    static func loadTimingSidecar(for audioURL: URL) -> CaptureTimingSidecar? {
        let sidecarURL = timingSidecarURL(for: audioURL)
        guard let data = try? Data(contentsOf: sidecarURL) else { return nil }
        return try? JSONDecoder().decode(CaptureTimingSidecar.self, from: data)
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
