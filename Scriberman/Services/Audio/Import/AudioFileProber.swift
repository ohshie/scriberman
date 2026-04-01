import AVFoundation
import CoreMedia
import Foundation

struct AudioFileProber {
    func probe(url: URL) async throws -> AudioImportProbeResult {
        let originalFileName = url.lastPathComponent
        let originalFormat = Self.defaultFormat(from: url)
        let title = Self.defaultTitle(from: url)

        let audioFile = try AVAudioFile(forReading: url)
        let fileDuration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0

        let asset = AVURLAsset(url: url)
        let loadedDuration = try await asset.load(.duration)
        let assetDuration = CMTimeGetSeconds(loadedDuration)
        let duration: TimeInterval
        if assetDuration.isFinite, assetDuration > 0 {
            duration = assetDuration
        } else {
            duration = max(0, fileDuration)
        }

        return AudioImportProbeResult(
            title: title,
            originalFileName: originalFileName,
            originalFormat: originalFormat,
            duration: duration
        )
    }

    private static func defaultTitle(from url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        return raw.isEmpty ? "Imported Audio" : raw
    }

    private static func defaultFormat(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "unknown" : ext
    }
}
