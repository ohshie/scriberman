import Foundation

@MainActor
final class NewSessionViewModel: ObservableObject {
    enum State {
        case idle
        case recording(duration: TimeInterval, level: Float)
        case stopped(session: RecordingSession)
    }

    @Published var state: State = .idle

    func reset() {
        state = .idle
    }
}
