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
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingRecoveryService")

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        fileManager: FileManager = .default,
        performMixdown: MixdownHandler? = nil
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.fileManager = fileManager
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

        // 4.3: Exclude .recording sessions (capture still in progress)
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
