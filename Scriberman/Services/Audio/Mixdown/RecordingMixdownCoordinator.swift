import Foundation
import OSLog
import SwiftData

protocol RecordingMixdownCoordinating: Sendable {
    /// Writes the mixdown and saves its location on the session. Returns whether both happened.
    /// Never deletes the raw inputs; `RecordingFinalizer` retires them (design D2).
    func runMixdown(
        sessionID: UUID,
        micURL: URL,
        appURL: URL?,
        mixdownURL: URL,
        micStartHostTime: HostNanoseconds,
        appStartHostTime: HostNanoseconds?,
        timelineMixdown: Bool
    ) async -> Bool
}

actor RecordingMixdownCoordinator: RecordingMixdownCoordinating {
    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let mixdownService: AudioMixdownService
    private let fileManager: FileManager
    private let sessionJobs: SessionJobs
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingMixdownCoordinator")

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        mixdownService: AudioMixdownService = AudioMixdownService(),
        fileManager: FileManager = .default,
        sessionJobs: SessionJobs = SessionJobs()
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.mixdownService = mixdownService
        self.fileManager = fileManager
        self.sessionJobs = sessionJobs
    }

    func runMixdown(
        sessionID: UUID,
        micURL: URL,
        appURL: URL?,
        mixdownURL: URL,
        micStartHostTime: HostNanoseconds,
        appStartHostTime: HostNanoseconds?,
        timelineMixdown: Bool
    ) async -> Bool {
        // In a task of its own, so a delete of the session cancels it and waits for it.
        await sessionJobs.run(sessionID) { generation in
            await self.mixdown(
                sessionID: sessionID,
                micURL: micURL,
                appURL: appURL,
                mixdownURL: mixdownURL,
                micStartHostTime: micStartHostTime,
                appStartHostTime: appStartHostTime,
                timelineMixdown: timelineMixdown,
                generation: generation
            )
        }
    }

    /// Writes the mixdown and saves its location, unless the session is deleted first. The mix
    /// itself cannot be interrupted, so a delete waits it out.
    private func mixdown(
        sessionID: UUID,
        micURL: URL,
        appURL: URL?,
        mixdownURL: URL,
        micStartHostTime: HostNanoseconds,
        appStartHostTime: HostNanoseconds?,
        timelineMixdown: Bool,
        generation: SessionJobs.Generation
    ) async -> Bool {
        guard sessionJobs.mayWrite(generation) else {
            logger.notice("Mixdown for session \(sessionID, privacy: .public) not started: the session was deleted.")
            return false
        }
        var scopedWorkspaceRoot: URL?
        var didStartScopedAccess = false
        if let workspace = await workspaceService.currentWorkspace(),
           micURL.path.hasPrefix(workspace.rootURL.path) {
            scopedWorkspaceRoot = workspace.rootURL
            didStartScopedAccess = workspace.rootURL.startAccessingSecurityScopedResource()
            logger.info(
                "Mixdown workspace scope for session \(sessionID, privacy: .public): started=\(didStartScopedAccess, privacy: .public) root=\(workspace.rootURL.path, privacy: .public)"
            )
        }
        defer {
            if didStartScopedAccess {
                scopedWorkspaceRoot?.stopAccessingSecurityScopedResource()
            }
        }

        logger.info(
            "Mixdown started for session \(sessionID, privacy: .public). mic=\(micURL.path, privacy: .public) app=\(appURL?.path ?? "nil", privacy: .public) out=\(mixdownURL.path, privacy: .public)"
        )
        let micSize = (try? fileManager.attributesOfItem(atPath: micURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        let appSize = appURL.flatMap { url in
            (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        } ?? -1
        logger.info(
            "Mixdown input sizes for session \(sessionID, privacy: .public). micBytes=\(micSize, privacy: .public) appBytes=\(appSize, privacy: .public)"
        )
        logger.info(
            "Mixdown timing for session \(sessionID, privacy: .public). micStart=\(micStartHostTime, privacy: .public) appStart=\(appStartHostTime?.description ?? "0", privacy: .public)"
        )
        do {
            try await mixdownService.mix(
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: micStartHostTime,
                appStartHostTime: appStartHostTime,
                into: mixdownURL,
                deleteSourceFiles: false,
                timelineMixdown: timelineMixdown
            )
        } catch {
            logger.error("Mixdown failed for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }

        let existsAfterMix = fileManager.fileExists(atPath: mixdownURL.path)
        logger.info(
            "Mixdown finished for session \(sessionID, privacy: .public). outputExists=\(existsAfterMix, privacy: .public) path=\(mixdownURL.path, privacy: .public)"
        )
        guard RecordingSourceFiles.isUsableMixdown(at: mixdownURL) else {
            logger.error("Mixdown output for session \(sessionID, privacy: .public) is unreadable or empty; not saving it.")
            return false
        }
        guard sessionJobs.mayWrite(generation) else {
            logger.notice("Mixdown for session \(sessionID, privacy: .public) not saved: the session was deleted.")
            return false
        }

        do {
            let context = ModelContext(modelContainer)
            guard let persistedSession = try RecordingSession.fetch(id: sessionID, in: context) else {
                logger.error("Mixdown succeeded but session \(sessionID, privacy: .public) was not found for persistence update.")
                return false
            }

            persistedSession.mixdownURL = mixdownURL.path
            try context.save()
            logger.info("Persisted mixdownURL for session \(sessionID, privacy: .public): \(mixdownURL.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to persist mixdown URL for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
