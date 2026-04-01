import AVFoundation
import CoreMedia
import Foundation
import SwiftData

struct AudioImportProbeResult {
    let title: String
    let originalFileName: String
    let originalFormat: String
    let duration: TimeInterval
}

actor AudioImportService {
    typealias ProbeAudio = @Sendable (URL) async throws -> AudioImportProbeResult
    typealias ReadChannelSamples = @Sendable (URL) throws -> [[Float]]
    typealias CreateDirectory = @Sendable (URL) throws -> Void
    typealias WriteMonoAAC = @Sendable ([Float], URL) async throws -> Void
    typealias MixToMonoM4A = @Sendable (URL, URL) async throws -> Void
    typealias Retranscribe = @Sendable (UUID, ModelContainer, Workspace) async -> Void
    typealias SaveContext = @Sendable (ModelContext) throws -> Void

    private let probeAudio: ProbeAudio
    private let readChannelSamples: ReadChannelSamples
    private let createDirectory: CreateDirectory
    private let writeMonoAAC: WriteMonoAAC
    private let mixToMonoM4A: MixToMonoM4A
    private let retranscribe: Retranscribe
    private let saveContext: SaveContext

    init(
        retranscriptionService: RetranscriptionService,
        probeAudio: ProbeAudio? = nil,
        readChannelSamples: ReadChannelSamples? = nil,
        createDirectory: CreateDirectory? = nil,
        writeMonoAAC: WriteMonoAAC? = nil,
        mixToMonoM4A: MixToMonoM4A? = nil,
        retranscribe: Retranscribe? = nil,
        saveContext: SaveContext? = nil
    ) {
        let mixdownService = AudioMixdownService()
        self.probeAudio = probeAudio ?? { url in
            try await Self.probeAudio(url: url)
        }
        self.readChannelSamples = readChannelSamples ?? { url in
            try Self.readChannelSamples(url: url)
        }
        self.createDirectory = createDirectory ?? { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        self.writeMonoAAC = writeMonoAAC ?? { samples, outputURL in
            try await mixdownService.writeMonoAAC(samples: samples, to: outputURL)
        }
        self.mixToMonoM4A = mixToMonoM4A ?? { inputURL, outputURL in
            try await mixdownService.mix(
                micURL: inputURL,
                appURL: nil,
                micStartHostTime: 0,
                appStartHostTime: nil,
                into: outputURL,
                deleteSourceFiles: false
            )
        }
        self.retranscribe = retranscribe ?? { sessionID, modelContainer, workspace in
            await retranscriptionService.retranscribe(sessionID: sessionID, modelContainer: modelContainer, workspace: workspace)
        }
        self.saveContext = saveContext ?? { context in
            try context.save()
        }
    }

    func importAudio(from url: URL, workspace: Workspace, modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        let fallbackTitle = Self.defaultTitle(from: url)
        let fallbackFileName = url.lastPathComponent
        let fallbackFormat = Self.defaultFormat(from: url)

        let hasInputScopeAccess = url.startAccessingSecurityScopedResource()
        let hasWorkspaceScopeAccess = workspace.rootURL.startAccessingSecurityScopedResource()
        defer {
            if hasInputScopeAccess {
                url.stopAccessingSecurityScopedResource()
            }
            if hasWorkspaceScopeAccess {
                workspace.rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let session = ImportedSession(
            duration: 0,
            title: fallbackTitle,
            originalFileName: fallbackFileName,
            originalFormat: fallbackFormat,
            status: .converting
        )
        
        context.insert(session)
        try? saveContext(context)
        
        let sessionID = session.id

        do {
            let probe = try await probeAudio(url)
            session.title = probe.title
            session.originalFileName = probe.originalFileName
            session.originalFormat = probe.originalFormat
            session.duration = probe.duration
            try? saveContext(context)

            let importFolderURL = makeUniqueImportFolderURL(
                title: session.title,
                createdAt: session.createdAt,
                workspace: workspace
            )
            try createDirectory(importFolderURL)

            let outputURL = importFolderURL.appendingPathComponent("recording.m4a")
            do {
                let channelSamples = try readChannelSamples(url)
                let monoSamples = downmixToMono(channelSamples: channelSamples)
                try await writeMonoAAC(monoSamples, outputURL)
            } catch {
                if shouldFallbackToMixdownService(for: error) {
                    try await mixToMonoM4A(url, outputURL)
                } else {
                    throw error
                }
            }

            session.mixdownURL = outputURL.path
            session.status = .transcribing
            try? saveContext(context)

            await retranscribe(sessionID, modelContainer, workspace)
        } catch {
            session.status = .error(error.localizedDescription)
            try? saveContext(context)
        }
    }

    private func makeUniqueImportFolderURL(title: String, createdAt: Date, workspace: Workspace) -> URL {
        let baseTitle = title.isEmpty ? "Imported Audio" : title
        let baseName = "\(baseTitle) at \(Self.hourMinute(createdAt))"
        let fileManager = FileManager.default

        var candidate = workspace.importsURL.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = workspace.importsURL.appendingPathComponent("\(baseName) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private static func probeAudio(url: URL) async throws -> AudioImportProbeResult {
        let originalFileName = url.lastPathComponent
        let originalFormat = defaultFormat(from: url)
        let title = defaultTitle(from: url)

        let audioFile = try AVAudioFile(forReading: url)
        let fileDuration = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate
            : 0

        let asset = AVURLAsset(url: url)
        let loadedDuration = try await asset.load(.duration)
        let assetDuration = CMTimeGetSeconds(loadedDuration)
        let duration: TimeInterval
        if assetDuration.isFinite, assetDuration > 0 {
            duration = assetDuration
        } else {
            duration = max(0, fileDuration)
        }

        return AudioImportProbeResult(
            title: title,
            originalFileName: originalFileName,
            originalFormat: originalFormat,
            duration: duration
        )
    }

    private static func readChannelSamples(url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else {
            throw RecordingError.failedToStart("Import failed: invalid channel count.")
        }

        var samplesByChannel = Array(repeating: [Float](), count: channelCount)
        let frameCapacity: AVAudioFrameCount = 4_096

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                throw RecordingError.failedToStart("Import failed: buffer allocation failed.")
            }
            try file.read(into: buffer, frameCount: frameCapacity)
            guard buffer.frameLength > 0 else {
                break
            }
            guard let channelData = buffer.floatChannelData else {
                throw RecordingError.failedToStart("Import failed: missing channel data.")
            }

            let frameCount = Int(buffer.frameLength)
            for channelIndex in 0..<channelCount {
                let channelSamples = Array(UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount))
                samplesByChannel[channelIndex].append(contentsOf: channelSamples)
            }
        }

        return samplesByChannel
    }

    private func downmixToMono(channelSamples: [[Float]]) -> [Float] {
        guard !channelSamples.isEmpty else {
            return []
        }
        if channelSamples.count == 1 {
            return channelSamples[0]
        }

        let frameCount = channelSamples[0].count
        var mono = Array(repeating: Float(0), count: frameCount)
        let channelCount = Float(channelSamples.count)

        for channel in channelSamples {
            guard channel.count == frameCount else {
                continue
            }
            for index in 0..<frameCount {
                mono[index] += channel[index]
            }
        }

        for index in 0..<frameCount {
            mono[index] /= channelCount
        }
        return mono
    }

    private static func defaultTitle(from url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        return raw.isEmpty ? "Imported Audio" : raw
    }

    private static func defaultFormat(from url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "unknown" : ext
    }

    private static func hourMinute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH-mm"
        return formatter.string(from: date)
    }

    private func shouldFallbackToMixdownService(for error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return true
        }

        let message = String(describing: error)
        return message.contains("Foundation._GenericObjCError")
            || message.contains("nilError")
    }
}
