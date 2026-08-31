import Foundation
import OSLog
import Testing
@testable import Scriberman

/// Spike coverage for task 1.1: can the app read back its own unified-log entries from inside the
/// sandbox? The failure-log writer is built on `OSLogStore(scope: .currentProcessIdentifier)`, and
/// this suite runs in the `Scriberman.app` test host, so it exercises the real entitlements.
struct SessionLogReadbackTests {
    @Test
    func testProcessCanReadBackItsOwnLogEntries() throws {
        let marker = UUID().uuidString
        let logger = Logger(subsystem: "Scriberman", category: "SessionLogReadbackProbe")
        let since = Date().addingTimeInterval(-5)
        logger.notice("session log readback probe \(marker, privacy: .public)")

        // The unified log is written asynchronously; give it a moment to land.
        Thread.sleep(forTimeInterval: 1.0)

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: since)
        let entries = try store.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "Scriberman" }

        #expect(!entries.isEmpty, "OSLogStore returned no Scriberman entries inside the sandbox")
        #expect(
            entries.contains { $0.composedMessage.contains(marker) },
            "the probe line was not readable back from the store"
        )
    }
}
