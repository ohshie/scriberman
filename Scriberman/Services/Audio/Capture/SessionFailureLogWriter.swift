import Foundation
import OSLog

/// Writes a session's log to `logs/<sessionID>.log` under the workspace root, on failure only.
///
/// Contents are pulled from the process's own unified-log entries rather than duplicated at every
/// call site: the app already logs richly, and the problem has never been too little logging but
/// that `os_log` evaporates. Deriving the file from the store captures everything already being
/// logged — including from code written before this existed — with no logging call changed.
///
/// Because a failed start is detected within a couple of seconds, the window is small and so is the
/// file.
struct SessionFailureLogWriter {
    struct Failure {
        let sessionID: UUID
        let startedAt: Date
        let micFrames: Int64?
        let appFrames: Int64?
        let micWriteFailures: Int
        let appWriteFailures: Int
        let restartAttempted: Bool
        let lastError: String?
    }

    private let fileManager: FileManager
    private let logger = Logger(subsystem: "Scriberman", category: "SessionFailureLogWriter")
    /// Injected so tests can exercise the writer without depending on the unified log.
    private let entriesProvider: (Date) -> [String]?

    init(
        fileManager: FileManager = .default,
        entriesProvider: ((Date) -> [String]?)? = nil
    ) {
        self.fileManager = fileManager
        self.entriesProvider = entriesProvider ?? Self.unifiedLogEntries
    }

    /// Writes the log and returns its URL. Returns nil only when the file could not be written.
    @discardableResult
    func write(_ failure: Failure, in workspace: Workspace) -> URL? {
        let contents = render(failure)
        let destination = workspace.logsURL.appendingPathComponent("\(failure.sessionID.uuidString).log")
        do {
            try fileManager.createDirectory(at: workspace.logsURL, withIntermediateDirectories: true)
            try contents.write(to: destination, atomically: true, encoding: .utf8)
            logger.notice("Wrote session failure log to \(destination.path, privacy: .public)")
            return destination
        } catch {
            logger.error("Failed to write session failure log: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func render(_ failure: Failure) -> String {
        var out = """
        Scriberman session failure log
        session: \(failure.sessionID.uuidString)
        started: \(ISO8601DateFormatter().string(from: failure.startedAt))
        written: \(ISO8601DateFormatter().string(from: Date()))

        Recording start verification failed: no audio frames were written.
        mic frames:          \(failure.micFrames.map(String.init) ?? "unavailable")
        app frames:          \(failure.appFrames.map(String.init) ?? "not captured")
        mic write failures:  \(failure.micWriteFailures)
        app write failures:  \(failure.appWriteFailures)
        restart attempted:   \(failure.restartAttempted)
        last error:          \(failure.lastError ?? "none")

        """

        // The summary above is written unconditionally, so the file is still useful when the
        // unified log cannot be read.
        if let entries = entriesProvider(failure.startedAt), !entries.isEmpty {
            out += "--- log entries ---\n"
            out += entries.joined(separator: "\n")
            out += "\n"
        } else {
            out += "--- log entries unavailable ---\n"
        }
        return out
    }

    private static func unifiedLogEntries(since: Date) -> [String]? {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: since)
            let formatter = ISO8601DateFormatter()
            return try store.getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == "Scriberman" }
                .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
        } catch {
            return nil
        }
    }
}
