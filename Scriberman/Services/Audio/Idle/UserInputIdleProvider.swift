import CoreGraphics
import Foundation

/// Reports when the user last touched the machine, used as an optional activity source for
/// the idle session prompt. This is what vetoes the "presenting for 15 minutes with everyone
/// else muted" case: you are clicking through slides even when app audio is silent.
protocol UserInputIdleProviding: Sendable {
    /// Seconds since the last mouse or keyboard event, or nil when unavailable.
    func secondsSinceLastInput() -> TimeInterval?
}

struct SystemUserInputIdleProvider: UserInputIdleProviding {
    func secondsSinceLastInput() -> TimeInterval? {
        // ~0 is kCGAnyInputEventType: any mouse, keyboard, or tablet event.
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}
