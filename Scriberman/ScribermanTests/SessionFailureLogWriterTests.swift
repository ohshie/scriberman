import Foundation
import Testing
@testable import Scriberman

struct SessionFailureLogWriterTests {
    private func makeWorkspace() -> Workspace {
        Workspace(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    private func makeFailure(sessionID: UUID = UUID()) -> SessionFailureLogWriter.Failure {
        SessionFailureLogWriter.Failure(
            sessionID: sessionID,
            startedAt: Date(timeIntervalSince1970: 1_756_000_000),
            micFrames: 0,
            appFrames: 0,
            micWriteFailures: 3,
            appWriteFailures: 0,
            restartAttempted: true,
            lastError: "Unable to start microphone capture."
        )
    }

    @Test
    func testWritesLogNamedForTheSessionUnderWorkspaceLogs() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let sessionID = UUID()
        let writer = SessionFailureLogWriter(entriesProvider: { _ in ["line one", "line two"] })

        let url = try #require(writer.write(makeFailure(sessionID: sessionID), in: workspace))

        #expect(url.lastPathComponent == "\(sessionID.uuidString).log")
        #expect(url.deletingLastPathComponent().lastPathComponent == "logs")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains(sessionID.uuidString))
        #expect(contents.contains("line one"))
        #expect(contents.contains("line two"))
    }

    @Test
    func testCreatesLogsDirectoryOnDemand() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        #expect(!FileManager.default.fileExists(atPath: workspace.logsURL.path))

        _ = SessionFailureLogWriter(entriesProvider: { _ in [] }).write(makeFailure(), in: workspace)

        #expect(FileManager.default.fileExists(atPath: workspace.logsURL.path))
    }

    /// The summary must survive even when the unified log cannot be read, because it carries the
    /// frame counts that say what actually failed.
    @Test
    func testWritesSummaryWhenLogEntriesAreUnavailable() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let writer = SessionFailureLogWriter(entriesProvider: { _ in nil })

        let url = try #require(writer.write(makeFailure(), in: workspace))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("log entries unavailable"))
        #expect(contents.contains("mic frames:          0"))
        #expect(contents.contains("mic write failures:  3"))
        #expect(contents.contains("restart attempted:   true"))
        #expect(contents.contains("Unable to start microphone capture."))
    }

    @Test
    func testReportsUnavailableAndNotCapturedCountsDistinctly() throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let failure = SessionFailureLogWriter.Failure(
            sessionID: UUID(),
            startedAt: Date(),
            micFrames: nil,
            appFrames: nil,
            micWriteFailures: 0,
            appWriteFailures: 0,
            restartAttempted: false,
            lastError: nil
        )

        let url = try #require(SessionFailureLogWriter(entriesProvider: { _ in [] }).write(failure, in: workspace))

        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("mic frames:          unavailable"))
        #expect(contents.contains("app frames:          not captured"))
    }
}
