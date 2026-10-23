import Foundation
import Testing
@testable import Scriberman

@MainActor
struct AppShellWindowTitleTests {
    @Test
    func noSelectionIsTitledSessions() {
        #expect(AppShellView.windowTitle(for: nil) == "Sessions")
    }

    @Test
    func pendingSessionIsTitledSessions() {
        let pending = PendingSession(title: "Weekly sync")
        #expect(AppShellView.windowTitle(for: .pending(pending)) == "Sessions")
    }

    @Test
    func recordingIsTitledAfterItsTitleAndFollowsRenames() {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/mic.wav", title: "Weekly sync", status: .recorded)
        #expect(AppShellView.windowTitle(for: .recording(session)) == "Weekly sync")

        session.title = "Planning"
        #expect(AppShellView.windowTitle(for: .recording(session)) == "Planning")
    }

    @Test
    func importIsTitledAfterItsTitle() {
        let session = ImportedSession(duration: 10, title: "Interview", originalFileName: "a.m4a", originalFormat: "m4a")
        #expect(AppShellView.windowTitle(for: .imported(session)) == "Interview")
    }

    @Test
    func blankTitleFallsBackToSessions() {
        let session = RecordingSession(duration: 10, micAudioURL: "/tmp/mic.wav", title: "  ", status: .recorded)
        #expect(AppShellView.windowTitle(for: .recording(session)) == "Sessions")
    }
}
