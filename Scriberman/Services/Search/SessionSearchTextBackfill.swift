import Foundation
import OSLog
import SwiftData

/// Gives sessions recorded before app-wide search the text they are searchable by.
///
/// New transcripts maintain it through the model's setters, so this exists only for what already
/// sits in the store. It runs at startup beside the tag backfill and is idempotent: a session that
/// already has its text, and a session that has no transcript at all, are both left alone.
///
/// Unlike the tag backfill it decodes rather than writing a default, so it decodes as little as it
/// can — only sessions missing their text *and* holding a transcript blob — and reports how long it
/// took, since that cost scales with a library nobody can size in advance.
struct SessionSearchTextBackfill {
    struct Result: Equatable {
        var recordingsUpdated: Int
        var importsUpdated: Int
        var duration: TimeInterval

        var totalUpdated: Int { recordingsUpdated + importsUpdated }
    }

    private let logger = Logger(subsystem: "Scriberman", category: "SessionSearchTextBackfill")
    /// Injected so tests can measure without a clock they do not control.
    private let now: @Sendable () -> Date

    init(now: (@Sendable () -> Date)? = nil) {
        self.now = now ?? { Date() }
    }

    @discardableResult
    func backfill(in context: ModelContext) throws -> Result {
        let started = now()

        let recordings = try refresh(try context.fetch(FetchDescriptor<RecordingSession>()))
        let imports = try refresh(try context.fetch(FetchDescriptor<ImportedSession>()))

        if recordings > 0 || imports > 0 {
            try context.save()
        }

        let result = Result(
            recordingsUpdated: recordings,
            importsUpdated: imports,
            duration: now().timeIntervalSince(started)
        )

        if result.totalUpdated > 0 {
            logger.notice(
                """
                Search text backfill: \(result.recordingsUpdated, privacy: .public) recording(s), \
                \(result.importsUpdated, privacy: .public) import(s) in \
                \(Int(result.duration * 1000), privacy: .public) ms.
                """
            )
        }

        return result
    }

    /// Refreshes the sessions that need it and returns how many were touched.
    ///
    /// A session with no transcript blob is skipped without decoding anything — the check that
    /// keeps a library of untranscribed recordings from paying for this at every launch.
    private func refresh(_ sessions: [some TranscribableSession]) throws -> Int {
        var updated = 0
        for session in sessions {
            guard session.searchableText == nil else { continue }
            guard session.transcriptData != nil || session.retranscriptData != nil else { continue }
            session.refreshSearchableText()
            if session.searchableText != nil {
                updated += 1
            }
        }
        return updated
    }
}
