import Foundation
import OSLog
import SwiftData

actor RecordingRecoveryService {
    static let maxMixdownAttempts = 3
    /// Screen mux retries stop after the same number of attempts as mixdown recovery.
    static let maxScreenMuxAttempts = maxMixdownAttempts
    typealias MixdownHandler = @Sendable (URL, URL?, URL) async throws -> Void
    typealias MuxHandler = @Sendable (ScreenVideoMuxRequest) async -> Void
    typealias RetireSources = @Sendable (_ micURL: URL, _ appURL: URL?) throws -> Void

    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let fileManager: FileManager
    private let performMixdown: MixdownHandler
    private let performMux: MuxHandler
    private let retireSources: RetireSources
    // Sessions whose finalization is running in this process are left to the finalizer.
    private let isFinalizing: @Sendable (UUID) -> Bool
    // No capture survives a process boundary: a .recording session created
    // before this instant is crash-interrupted by definition (design D1).
    private let launchedAt: Date
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingRecoveryService")

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        fileManager: FileManager = .default,
        launchedAt: Date = .now,
        performMixdown: MixdownHandler? = nil,
        performMux: MuxHandler? = nil,
        retireSources: @escaping RetireSources = { try RecordingSourceFiles.retire(micURL: $0, appURL: $1) },
        isFinalizing: @escaping @Sendable (UUID) -> Bool = { _ in false }
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
                    micStartHostTime: HostNanoseconds(nanoseconds: 0),
                    appStartHostTime: nil,
                    into: outputURL,
                    deleteSourceFiles: false
                )
            }
        }
        if let performMux {
            self.performMux = performMux
        } else {
            let muxer = ScreenVideoMuxer(workspaceService: workspaceService, modelContainer: modelContainer)
            self.performMux = { await muxer.runMux(request: $0) }
        }
        self.retireSources = retireSources
        self.isFinalizing = isFinalizing
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
        // and sessions this process is still finalizing.
        let candidates = sessions.filter { session in
            if case .recording = session.status { return false }
            return !isFinalizing(session.id)
        }

        var eligible: [RecordingSession] = []
        for session in candidates where session.mixdownURL == nil {
            if adoptCompletedMixdown(session, context: context) { continue }
            if fileManager.fileExists(atPath: session.micAudioURL) {
                eligible.append(session)
            }
        }

        logger.info("Recovery sweep: \(eligible.count, privacy: .public) eligible session(s)")
        for session in eligible {
            await recoverSession(session, context: context)
        }

        for session in candidates {
            await retryScreenMuxIfNeeded(session, context: context)
        }
        for session in candidates {
            retireLeftoverSourcesIfNeeded(session)
        }
    }

    private func mixdownURL(for session: RecordingSession) -> URL {
        URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent().appendingPathComponent("recording.m4a")
    }

    /// Saves a readable `recording.m4a` left by an interrupted finalization as the session's
    /// mixdown, so the raw inputs are not required (design D4).
    private func adoptCompletedMixdown(_ session: RecordingSession, context: ModelContext) -> Bool {
        let outputURL = mixdownURL(for: session)
        guard fileManager.fileExists(atPath: outputURL.path),
              RecordingSourceFiles.isUsableMixdown(at: outputURL)
        else {
            return false
        }
        session.mixdownURL = outputURL.path
        switch session.status {
        case .converting, .error:
            session.status = .recorded
        default:
            break
        }
        do {
            try context.save()
            logger.info("Adopted existing mixdown for session \(session.id, privacy: .public)")
            return true
        } catch {
            logger.error("Saving adopted mixdown failed for session \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Retries a pending or failed screen mux with the mixdown as its audio (design D3). Each
    /// attempt is counted before it starts, so a quit mid-mux still uses one up.
    private func retryScreenMuxIfNeeded(_ session: RecordingSession, context: ModelContext) async {
        guard let state = session.screenMuxState,
              ScreenMuxState(rawValue: state) != nil,
              let videoStartNanos = session.videoStartHostTimeNanos,
              let mixdownPath = session.mixdownURL,
              session.screenMuxAttemptCount < Self.maxScreenMuxAttempts
        else {
            return
        }
        let folderURL = URL(fileURLWithPath: session.micAudioURL).deletingLastPathComponent()
        let screenTmpURL = RecordingFileLayout.screenTmpVideoURL(in: folderURL)
        let mixdownURL = URL(fileURLWithPath: mixdownPath)
        guard fileManager.fileExists(atPath: screenTmpURL.path),
              fileManager.fileExists(atPath: mixdownURL.path)
        else {
            return
        }

        session.screenMuxAttemptCount += 1
        let attempt = session.screenMuxAttemptCount
        try? context.save()
        logger.info("Retrying screen mux for session \(session.id, privacy: .public), attempt \(attempt, privacy: .public)")

        let micURL = URL(fileURLWithPath: session.micAudioURL)
        let anchor = session.audioAnchorHostTimeNanos.map { HostNanoseconds(nanoseconds: UInt64(clamping: $0)) }
        await performMux(ScreenVideoMuxRequest(
            sessionID: session.id,
            screenTmpURL: screenTmpURL,
            screenVideoURL: RecordingFileLayout.screenVideoURL(in: folderURL),
            micURL: micURL,
            appURL: session.appAudioURL.map { URL(fileURLWithPath: $0) },
            micStartHostTime: nil,
            appStartHostTime: nil,
            videoStartHostTime: HostNanoseconds(nanoseconds: UInt64(clamping: videoStartNanos)),
            timelineAudioURL: mixdownURL,
            audioAnchorHostTime: anchor
        ))
    }

    /// Deletes raw inputs a finished finalization left behind (design D2). Requires a usable
    /// mixdown. A screen mux retry reads the mixdown, not these files.
    private func retireLeftoverSourcesIfNeeded(_ session: RecordingSession) {
        guard let mixdownPath = session.mixdownURL else { return }
        let micURL = URL(fileURLWithPath: session.micAudioURL)
        let appURL = session.appAudioURL.map { URL(fileURLWithPath: $0) }
        guard RecordingSourceFiles.anyExist(micURL: micURL, appURL: appURL, fileManager: fileManager),
              RecordingSourceFiles.isUsableMixdown(at: URL(fileURLWithPath: mixdownPath))
        else {
            return
        }
        do {
            try retireSources(micURL, appURL)
            logger.info("Retired leftover raw inputs for session \(session.id, privacy: .public)")
        } catch {
            logger.error("Retiring leftover raw inputs failed for session \(session.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func repairWavIfNeeded(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            if try WavHeaderRepairer.repairIfNeeded(at: url) {
                logger.info("Repaired crash-stale WAV header: \(url.lastPathComponent, privacy: .public)")
            }
        } catch {
            logger.warning("WAV header repair skipped for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

        // Crash-stale WAV headers make the data unreadable; repair before
        // mixdown (design D2). Failures are non-fatal — the mixdown attempt
        // below flows into the bounded-retry machinery either way.
        repairWavIfNeeded(at: micURL)
        if let appURL {
            repairWavIfNeeded(at: appURL)
        }

        do {
            try await performMixdown(micURL, appURL, outputURL)
            session.mixdownURL = outputURL.path
            session.status = .recorded
            try? context.save()
            logger.info("Recovery mixdown succeeded for session \(sessionID, privacy: .public)")
            // The inputs are retired by the leftover-source step once the saved mixdown is usable.
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
