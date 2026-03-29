import Foundation

enum TimeFormatter {
    static func format(seconds: Float) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }

        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    static func formatWithMilliseconds(seconds: Float) -> String {
        let totalMilliseconds = max(0, Int((Double(seconds) * 1_000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let remainingSeconds = (totalMilliseconds % 60_000) / 1_000
        let milliseconds = totalMilliseconds % 1_000

        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, remainingSeconds, milliseconds)
    }
}
