import Foundation
import OSLog
import SwiftData

actor RecordingRecoveryService {
    static let maxMixdownAttempts = 3
    typealias MixdownHandler = @Sendable (URL, URL?, URL) async throws -> Void

    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let fileManager: FileManager
    private let performMixdown: MixdownHandler
    // No capture survives a process boundary: a .recording session created
    // before this instant is crash-interrupted by definition (design D1).
    private let launchedAt: Date
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingRecoveryService")

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        fileManager: FileManager = .default,
        launchedAt: Date = .now,
        performMixdown: MixdownHandler? = nil
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.fileManager = fileManager
        self.launchedAt = launchedAt
        if let performMixdown {
            self.performMixdown = performMixdown
        } else {
            let mixdownService = AudioMixdownService()
            self.performMixdown = { micURL, appURL, outputURL in
                try await mixdownService.mix(
                    micURL: micURL,
                    appURL: appURL,
                    micStartHostTime: 0,
                    appStartHostTime: nil,
                    into: outputURL
                )
            }
        }
    }

    func sweepIncompleteSessions() async {
        guard let workspace = await workspaceService.currentWorkspace() else {
            logger.info("Recovery sweep skipped: no workspace configured")
            return
        }

        let didStartAccess = workspace.rootURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                workspace.rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let context = ModelContext(modelContainer)
        let sessions: [RecordingSession]
        do {
            sessions = try context.fetch(FetchDescriptor<RecordingSession>())
        } catch {
            logger.error("Recovery sweep fetch failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        normalizeCrashInterruptedSessions(sessions, context: context)

        // Exclude .recording sessions (capture still in progress — only
        // post-launch sessions can still carry this status after normalization)
        let eligible = sessions.filter { session in
            guard session.mixdownURL == nil else { return false }
            if case .recording = session.status { return false }
            return fileManager.fileExists(atPath: session.micAudioURL)
        }

        logger.info("Recovery sweep: \(eligible.count, privacy: .public) eligible session(s)")
        for session in eligible {
            await recoverSession(session, context: context)
        }
    }

    /// Flips sessions stranded in `.recording` by a crash or power loss so
    /// they become eligible for mixdown recovery. Sessions created after this
    /// process launched are never touched — they may be genuinely recording.
    private func normalizeCrashInterruptedSessions(_ sessions: [RecordingSession], context: ModelContext) {
        var normalizedCount = 0
        for session in sessions {
            guard case .recording = session.status, session.createdAt < launchedAt else { continue }
            if fileManager.fileExists(atPath: session.micAudioURL) {
                session.status = .recorded
                logger.info("Normalized crash-interrupted session \(session.id, privacy: .public) to .recorded")
            } else {
                session.status = .error("Recording was interrupted before audio was saved.")
                logger.info("Crash-interrupted session \(session.id, privacy: .public) has no audio on disk; marked as error")
            }
            normalizedCount += 1
        }
        if normalizedCount > 0 {
            try? context.save()
        }
    }

    private func recoverSession(_ session: RecordingSession, context: ModelContext) async {
        let sessionID = session.id

        // 4.2: Already exhausted attempts — ensure error state is set and bail
        if session.mixdownAttemptCount >= Self.maxMixdownAttempts {
            if case .error = session.status { return }
            session.status = .error("Mixdown failed after \(Self.maxMixdownAttempts) attempts.")
            try? context.save()
            return
        }

        let micURL = URL(fileURLWithPath: session.micAudioURL)
        let appURL = session.appAudioURL.map { URL(fileURLWithPath: $0) }
        let outputURL = micURL.deletingLastPathComponent().appendingPathComponent("recording.m4a")

        session.status = .converting
        try? context.save()

        do {
            try await performMixdown(micURL, appURL, outputURL)
            session.mixdownURL = outputURL.path
            session.status = .recorded
            try? context.save()
            logger.info("Recovery mixdown succeeded for session \(sessionID, privacy: .public)")
        } catch {
            session.mixdownAttemptCount += 1
            let attempts = session.mixdownAttemptCount
            logger.error("Recovery mixdown attempt \(attempts, privacy: .public) failed for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // 4.2: Transition to .error after exhausting retries
            if attempts >= Self.maxMixdownAttempts {
                session.status = .error("Mixdown failed after \(Self.maxMixdownAttempts) attempts.")
            } else {
                session.status = .recorded
            }
            try? context.save()
        }
    }
}
