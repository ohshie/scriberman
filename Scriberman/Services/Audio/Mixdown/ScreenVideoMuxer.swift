import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import OSLog
import SwiftData

protocol ScreenCaptureSessionControlling: AnyObject, Sendable {
    var onError: (@Sendable (Error) -> Void)? { get set }
    var videoStartHostTime: UInt64? { get }
    func start(displayID: CGDirectDisplayID, videoURL: URL) async throws
    func stop() async
}

extension ScreenCaptureSession: ScreenCaptureSessionControlling {}

protocol ScreenVideoMuxing: Sendable {
    func runMux(request: ScreenVideoMuxRequest) async
}

struct ScreenVideoMuxRequest: Sendable {
    let sessionID: UUID
    let screenTmpURL: URL
    let screenVideoURL: URL
    let micURL: URL
    let appURL: URL?
    let micStartHostTime: UInt64?
    let appStartHostTime: UInt64?
    let videoStartHostTime: UInt64
}

struct ScreenVideoTrackInstruction: Equatable, Sendable {
    let label: String
    let url: URL
    let sourceStart: CMTime
    let insertionTime: CMTime
}

struct ScreenVideoMuxPlan: Sendable {
    let request: ScreenVideoMuxRequest
    let audioInstructions: [ScreenVideoTrackInstruction]
}

protocol ScreenVideoExporting: Sendable {
    func export(plan: ScreenVideoMuxPlan) async throws
}

actor ScreenVideoMuxer: ScreenVideoMuxing {
    private let workspaceService: WorkspaceServiceProtocol
    private let modelContainer: ModelContainer
    private let exporter: ScreenVideoExporting
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "Scriberman", category: "ScreenVideoMuxer")

    init(
        workspaceService: WorkspaceServiceProtocol,
        modelContainer: ModelContainer,
        exporter: ScreenVideoExporting = AVFoundationScreenVideoExporter(),
        fileManager: FileManager = .default
    ) {
        self.workspaceService = workspaceService
        self.modelContainer = modelContainer
        self.exporter = exporter
        self.fileManager = fileManager
    }

    func runMux(request: ScreenVideoMuxRequest) async {
        var scopedWorkspaceRoot: URL?
        var didStartScopedAccess = false
        if let workspace = await workspaceService.currentWorkspace(),
           request.screenTmpURL.path.hasPrefix(workspace.rootURL.path) {
            scopedWorkspaceRoot = workspace.rootURL
            didStartScopedAccess = workspace.rootURL.startAccessingSecurityScopedResource()
        }
        defer {
            if didStartScopedAccess {
                scopedWorkspaceRoot?.stopAccessingSecurityScopedResource()
            }
        }

        let plan: ScreenVideoMuxPlan
        do {
            plan = buildPlan(request: request)
            try await exporter.export(plan: plan)
            try await persistScreenVideoURL(
                sessionID: request.sessionID,
                screenVideoURL: request.screenVideoURL
            )
            cleanupTemporaryVideo(at: request.screenTmpURL)
        } catch {
            logger.error("Screen video mux failed for session \(request.sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            cleanupTemporaryVideo(at: request.screenTmpURL)
        }
    }

    func buildPlan(request: ScreenVideoMuxRequest) -> ScreenVideoMuxPlan {
        let audioInstructions = Self.makeAudioInstructions(
            micURL: request.micURL,
            appURL: request.appURL,
            micStartHostTime: request.micStartHostTime,
            appStartHostTime: request.appStartHostTime,
            videoStartHostTime: request.videoStartHostTime,
            fileManager: fileManager
        )
        return ScreenVideoMuxPlan(request: request, audioInstructions: audioInstructions)
    }

    private func persistScreenVideoURL(
        sessionID: UUID,
        screenVideoURL: URL
    ) throws {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<RecordingSession>()
        let sessions = try context.fetch(descriptor)
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            throw RecordingError.failedToStart("Screen video mux succeeded but the session could not be found.")
        }
        session.screenVideoURL = screenVideoURL.path
        try context.save()
    }

    private func cleanupTemporaryVideo(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Failed to remove temporary screen video \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    static func makeAudioInstructions(
        micURL: URL,
        appURL: URL?,
        micStartHostTime: UInt64?,
        appStartHostTime: UInt64?,
        videoStartHostTime: UInt64,
        fileManager: FileManager = .default
    ) -> [ScreenVideoTrackInstruction] {
        var instructions: [ScreenVideoTrackInstruction] = []

        if fileManager.fileExists(atPath: micURL.path) {
            instructions.append(
                makeInstruction(
                    label: "mic",
                    url: micURL,
                    sourceStartHostTime: micStartHostTime ?? videoStartHostTime,
                    videoStartHostTime: videoStartHostTime
                )
            )
        }

        if let appURL, fileManager.fileExists(atPath: appURL.path) {
            instructions.append(
                makeInstruction(
                    label: "app",
                    url: appURL,
                    sourceStartHostTime: appStartHostTime ?? videoStartHostTime,
                    videoStartHostTime: videoStartHostTime
                )
            )
        }

        return instructions
    }

    private static func makeInstruction(
        label: String,
        url: URL,
        sourceStartHostTime: UInt64,
        videoStartHostTime: UInt64
    ) -> ScreenVideoTrackInstruction {
        let deltaSeconds = Double(Int64(sourceStartHostTime) - Int64(videoStartHostTime)) / 1_000_000_000
        if deltaSeconds >= 0 {
            return ScreenVideoTrackInstruction(
                label: label,
                url: url,
                sourceStart: .zero,
                insertionTime: CMTime(seconds: deltaSeconds, preferredTimescale: 600)
            )
        }

        return ScreenVideoTrackInstruction(
            label: label,
            url: url,
            sourceStart: CMTime(seconds: abs(deltaSeconds), preferredTimescale: 600),
            insertionTime: .zero
        )
    }
}

private struct AVFoundationScreenVideoExporter: ScreenVideoExporting {
    func export(plan: ScreenVideoMuxPlan) async throws {
        let request = plan.request
        let composition = AVMutableComposition()

        let videoAsset = AVURLAsset(url: request.screenTmpURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first,
              let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw RecordingError.failedToStart("Temporary screen recording does not contain a video track.")
        }

        let videoDuration = try await videoAsset.load(.duration)
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )

        for instruction in plan.audioInstructions {
            let audioAsset = AVURLAsset(url: instruction.url)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            guard let audioTrack = audioTracks.first,
                  let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else {
                continue
            }

            let audioDuration = try await audioAsset.load(.duration)
            let availableDuration = CMTimeSubtract(audioDuration, instruction.sourceStart)
            guard availableDuration > .zero else {
                continue
            }

            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: instruction.sourceStart, duration: availableDuration),
                of: audioTrack,
                at: instruction.insertionTime
            )
        }

        if FileManager.default.fileExists(atPath: request.screenVideoURL.path) {
            try FileManager.default.removeItem(at: request.screenVideoURL)
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw RecordingError.failedToStart("Failed to create export session for screen video.")
        }

        exportSession.outputURL = request.screenVideoURL
        exportSession.outputFileType = .mov
        exportSession.shouldOptimizeForNetworkUse = false

        try await exportSession.performExport()

        if exportSession.status != .completed {
            throw exportSession.error ?? RecordingError.failedToStart("Screen video export did not complete.")
        }
    }
}

private extension AVAssetExportSession {
    func performExport() async throws {
        try await withCheckedThrowingContinuation { continuation in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: self.error ?? RecordingError.failedToStart("Screen video export failed."))
                default:
                    continuation.resume(throwing: RecordingError.failedToStart("Screen video export finished in an unexpected state."))
                }
            }
        }
    }
}
