import Foundation
import SwiftData

/// Why an import could not begin.
enum AudioImportError: Error, Equatable {
    /// The new session could not be saved, so nothing was converted.
    case couldNotRecord(String)
}

struct AudioImportProbeResult {
    let title: String
    let originalFileName: String
    let originalFormat: String
    let duration: TimeInterval
}

actor AudioImportService {
    typealias ProbeAudio = @Sendable (URL) async throws -> AudioImportProbeResult
    typealias ReadChannelSamples = @Sendable (URL) throws -> DecodedAudio
    typealias CreateDirectory = @Sendable (URL) throws -> Void
    typealias WriteMonoAAC = @Sendable ([Float], URL) async throws -> Void
    typealias MixToMonoM4A = @Sendable (URL, URL) async throws -> Void
    typealias Retranscribe = @Sendable (UUID, ModelContainer, Workspace, LiveTranscriptionPipelineSettings) async -> Void
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
        audioFileProber: AudioFileProber = AudioFileProber(),
        audioChannelReader: AudioChannelReader = AudioChannelReader(),
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
            try await audioFileProber.probe(url: url)
        }
        self.readChannelSamples = readChannelSamples ?? { url in
            try audioChannelReader.read(url: url)
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
                micStartHostTime: HostNanoseconds(nanoseconds: 0),
                appStartHostTime: nil,
                into: outputURL,
                deleteSourceFiles: false
            )
        }
        self.retranscribe = retranscribe ?? { sessionID, modelContainer, workspace, pipelineSettings in
            await retranscriptionService.retranscribe(
                sessionID: sessionID,
                modelContainer: modelContainer,
                workspace: workspace,
                pipelineSettings: pipelineSettings
            )
        }
        self.saveContext = saveContext ?? { context in
            try context.save()
        }
    }

    /// Imports `url` as a new session.
    ///
    /// Throws only when the session itself cannot be saved: conversion does not start, since its
    /// progress and result would belong to a record the store never took. Every later failure is
    /// recorded on the session as its error status instead.
    func importAudio(
        from url: URL,
        workspace: Workspace,
        modelContainer: ModelContainer,
        pipelineSettings: LiveTranscriptionPipelineSettings = .defaults
    ) async throws {
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
        do {
            try saveContext(context)
        } catch {
            throw AudioImportError.couldNotRecord(error.localizedDescription)
        }

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
                let decoded = try readChannelSamples(url)
                let monoSamples = AudioDownmixer.toMono(channelSamples: decoded.channels)
                // The writer is fixed at the mixdown output rate, so samples decoded at any other
                // rate are converted first; written unconverted they would play at the wrong speed.
                let outputSamples = try AudioResampler(targetSampleRate: AudioMixdownService.outputSampleRate)
                    .resample(monoSamples, from: decoded.sampleRate)
                try await writeMonoAAC(outputSamples, outputURL)
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

            await retranscribe(sessionID, modelContainer, workspace, pipelineSettings)
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
