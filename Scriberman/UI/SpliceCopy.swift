import Foundation

/// Approved strings from session-splice ticket 02.
enum SpliceCopy {
    static func apply(_ count: Int) -> String { count == 1 ? "Splice into 1 part" : "Splice into \(count) parts" }

    static func restorePartialMessage(_ count: Int) -> String {
        count == 1
            ? "1 part could not be moved to Pending deletions and is still in your list."
            : "\(count) parts could not be moved to Pending deletions and are still in your list."
    }

    static func errorMessage(_ error: Error) -> String {
        switch error as? SpliceError {
        case .insufficientDiskSpace: "Not enough disk space to splice this recording"
        case .missingOriginal, .missingMixdown: "The original recording files could not be found."
        case .stalePlan: "The transcript changed while you were editing"
        case .busy, .unfinishedRecording: "Another part of this recording is busy. Try again when it finishes."
        case .inactiveWorkspace: "This session is in another workspace. Switch to that workspace and try again."
        default: "Something went wrong while writing the files. The recording was not changed."
        }
    }

    static func length(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: max(0, seconds)) ?? TimeFormatter.displayFormat(seconds: Float(seconds))
    }
}
