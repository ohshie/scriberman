import Foundation
import OSLog
import SwiftData

actor RecordingMixdownCoordinator {
    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let mixdownService: AudioMixdownService
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingMixdownCoordinator")

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        mixdownService: AudioMixdownService = AudioMixdownService(),
        fileManager: FileManager = .default
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.mixdownService = mixdownService
        self.fileManager = fileManager
    }

    func runMixdown(
        sessionID: UUID,
        micURL: URL,
        appURL: URL?,
        mixdownURL: URL,
        micStartHostTime: UInt64,
        appStartHostTime: UInt64?
    ) async {
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
            "Mixdown timing for session \(sessionID, privacy: .public). micStart=\(micStartHostTime, privacy: .public) appStart=\(appStartHostTime ?? 0, privacy: .public)"
        )
        do {
            try await mixdownService.mix(
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: micStartHostTime,
                appStartHostTime: appStartHostTime,
                into: mixdownURL
            )
        } catch {
            logger.error("Mixdown failed for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let existsAfterMix = fileManager.fileExists(atPath: mixdownURL.path)
        logger.info(
            "Mixdown finished for session \(sessionID, privacy: .public). outputExists=\(existsAfterMix, privacy: .public) path=\(mixdownURL.path, privacy: .public)"
        )

        do {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<RecordingSession>()
            let sessions = try context.fetch(descriptor)
            var persistedSession: RecordingSession?
            for session in sessions where session.id == sessionID {
                persistedSession = session
                break
            }
            guard let persistedSession else {
                logger.error("Mixdown succeeded but session \(sessionID, privacy: .public) was not found for persistence update.")
                return
            }

            persistedSession.mixdownURL = mixdownURL.path
            try context.save()
            logger.info("Persisted mixdownURL for session \(sessionID, privacy: .public): \(mixdownURL.path, privacy: .public)")
        } catch {
            logger.error("Failed to persist mixdown URL for session \(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
