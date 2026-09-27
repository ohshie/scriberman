import AVFoundation
import Foundation
import OSLog
import os

/// Everything one recording's finalization needs after capture stops.
struct RecordingFinalizationJob: Sendable {
    let sessionID: UUID
    let micURL: URL
    let appURL: URL?
    let mixdownURL: URL
    let micStartHostTime: HostNanoseconds
    let appStartHostTime: HostNanoseconds?
    /// Set when the recording has video to mux.
    let screenMux: ScreenVideoMuxRequest?
}

protocol RecordingFinalizing: Sendable {
    /// Whether any finalization job is still running. Readable from any thread.
    nonisolated var hasJobs: Bool { get }
    /// Waits until no job is running or `timeout` passes. Returns whether all jobs finished.
    func waitForAll(timeout: Duration) async -> Bool
}

/// Owns each recording's finalization: mixdown, then the screen mux when there is video, then
/// retirement of the raw capture files (design D1, D2). No step deletes an input before its
/// output is referenced in the store.
actor RecordingFinalizer: RecordingFinalizing {
    typealias RetireSources = @Sendable (_ micURL: URL, _ appURL: URL?) throws -> Void

    private let mixdownCoordinator: any RecordingMixdownCoordinating
    private let screenVideoMuxer: any ScreenVideoMuxing
    private let retireSources: RetireSources
    private let logger = Logger(subsystem: "Scriberman", category: "RecordingFinalizer")

    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    // Mirrors `jobs.keys` for nonisolated readers: quit handling and recovery.
    private let activeSessions = OSAllocatedUnfairLock(initialState: Set<UUID>())

    init(
        mixdownCoordinator: any RecordingMixdownCoordinating,
        screenVideoMuxer: any ScreenVideoMuxing,
        retireSources: @escaping RetireSources = { try RecordingSourceFiles.retire(micURL: $0, appURL: $1) }
    ) {
        self.mixdownCoordinator = mixdownCoordinator
        self.screenVideoMuxer = screenVideoMuxer
        self.retireSources = retireSources
    }

    nonisolated var hasJobs: Bool {
        activeSessions.withLock { !$0.isEmpty }
    }

    nonisolated func isFinalizing(sessionID: UUID) -> Bool {
        activeSessions.withLock { $0.contains(sessionID) }
    }

    /// Starts the job and returns without waiting for it. A second job for the same session
    /// runs after the first.
    func schedule(_ job: RecordingFinalizationJob) {
        let previous = jobs[job.sessionID]
        let sessionID = job.sessionID
        activeSessions.withLock { _ = $0.insert(sessionID) }
        jobs[sessionID] = Task { [weak self] in
            await previous?.value
            await self?.run(job)
            await self?.finish(sessionID: sessionID)
        }
    }

    func waitForAll(timeout: Duration) async -> Bool {
        guard !jobs.isEmpty else { return true }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            idleWaiters[waiterID] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resumeWaiter(waiterID, allFinished: false)
            }
        }
    }

    private func run(_ job: RecordingFinalizationJob) async {
        let committed = await mixdownCoordinator.runMixdown(
            sessionID: job.sessionID,
            micURL: job.micURL,
            appURL: job.appURL,
            mixdownURL: job.mixdownURL,
            micStartHostTime: job.micStartHostTime,
            appStartHostTime: job.appStartHostTime
        )

        // Runs after the mixdown on both paths, so the legacy mux still finds the raw inputs.
        if let screenMux = job.screenMux {
            await screenVideoMuxer.runMux(request: screenMux)
        }

        guard committed else {
            logger.notice("Keeping raw inputs for session \(job.sessionID, privacy: .public): mixdown was not committed.")
            return
        }
        do {
            try retireSources(job.micURL, job.appURL)
            logger.info("Retired raw inputs for session \(job.sessionID, privacy: .public)")
        } catch {
            logger.error("Retiring raw inputs failed for session \(job.sessionID, privacy: .public); recovery retries: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func finish(sessionID: UUID) {
        jobs[sessionID] = nil
        activeSessions.withLock { _ = $0.remove(sessionID) }
        guard jobs.isEmpty else { return }
        for waiterID in Array(idleWaiters.keys) {
            resumeWaiter(waiterID, allFinished: true)
        }
    }

    private func resumeWaiter(_ waiterID: UUID, allFinished: Bool) {
        idleWaiters.removeValue(forKey: waiterID)?.resume(returning: allFinished)
    }
}

/// Checks and removal for a recording's raw capture files.
enum RecordingSourceFiles {
    /// The raw WAVs and their timing sidecars.
    static func sourceURLs(micURL: URL, appURL: URL?) -> [URL] {
        [micURL, appURL].compactMap { $0 }.flatMap { [$0, AudioFileStreamer.timingSidecarURL(for: $0)] }
    }

    /// Whether any raw WAV or sidecar is still on disk.
    static func anyExist(micURL: URL, appURL: URL?, fileManager: FileManager = .default) -> Bool {
        sourceURLs(micURL: micURL, appURL: appURL).contains { fileManager.fileExists(atPath: $0.path) }
    }

    /// Deletes the raw WAVs and sidecars that exist. Throws the first failure after trying all.
    static func retire(micURL: URL, appURL: URL?, fileManager: FileManager = .default) throws {
        var firstError: Error?
        for url in sourceURLs(micURL: micURL, appURL: appURL) where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }

    /// Whether `url` is an audio file that opens and has a positive length (design D4).
    static func isUsableMixdown(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }
}
