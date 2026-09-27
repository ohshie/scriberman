import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class TrimEditorViewModel {
    let session: RecordingSession
    var trimPosition: Double
    var isApplying = false
    var error: Error?
    var showRestoreConfirmation = false

    private let trimService = AudioTrimService()
    private let audioPlayer: AudioPlayerViewModel
    private let context: ModelContext

    init(session: RecordingSession, audioPlayer: AudioPlayerViewModel, context: ModelContext) {
        self.session = session
        self.audioPlayer = audioPlayer
        self.context = context
        self.trimPosition = session.trimEnd ?? session.duration
    }

    var keepRangeLabel: String {
        "Keep: 0:00 → \(formatTime(trimPosition))"
    }

    var isAtFullDuration: Bool {
        trimPosition >= session.duration
    }

    func preview() {
        let previewStart = max(0, trimPosition - 5)
        audioPlayer.seek(to: previewStart)
        audioPlayer.play()
    }

    func applyTrim() async {
        audioPlayer.stop()
        isApplying = true
        error = nil
        do {
            try await trimService.trim(session: session, end: trimPosition, context: context)
            audioPlayer.reload()
        } catch {
            self.error = error
        }
        isApplying = false
    }

    func restore() async {
        audioPlayer.stop()
        isApplying = true
        error = nil
        do {
            try await trimService.restore(session: session, context: context)
            audioPlayer.reload()
        } catch {
            self.error = error
        }
        isApplying = false
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}
