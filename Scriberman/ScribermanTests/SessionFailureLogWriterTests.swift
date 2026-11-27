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
            kind: .startVerification,
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
            kind: .startVerification,
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

    @Test(arguments: [
        (SessionFailureLogWriter.Failure.Kind.startVerification, "Recording failed to start: no audio."),
        (.restartsExhausted, "Recording stopped: audio capture did not recover."),
    ])
    func testEachFailureKindHasItsOwnHeader(kind: SessionFailureLogWriter.Failure.Kind, header: String) throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let failure = SessionFailureLogWriter.Failure(
            kind: kind,
            sessionID: UUID(),
            startedAt: Date(),
            micFrames: 5_933_728,
            appFrames: 7_495_680,
            micWriteFailures: 0,
            appWriteFailures: 0,
            restartAttempted: true,
            lastError: nil
        )

        let url = try #require(SessionFailureLogWriter(entriesProvider: { _ in [] }).write(failure, in: workspace))

        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        #expect(lines.contains(header))
        #expect(!lines.contains("Recording start verification failed: no audio frames were written."))
    }
}
