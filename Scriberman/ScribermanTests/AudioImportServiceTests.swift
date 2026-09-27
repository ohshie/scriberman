import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Scriberman

final class AudioImportServiceTests {
    private final class LockedValue<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T

        init(_ value: T) {
            self.value = value
        }

        func set(_ newValue: T) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private let container: ModelContainer
    private let context: ModelContext
    private let workspaceRootURL: URL

    private static func updateImportedSession(
        id sessionID: UUID,
        in modelContainer: ModelContainer,
        update: (ImportedSession) -> Void
    ) {
        let ctx = ModelContext(modelContainer)
        guard let session = try? ctx.fetch(FetchDescriptor<ImportedSession>()).first(where: { $0.id == sessionID }) else {
            return
        }
        update(session)
        try? ctx.save()
    }

    init() throws {
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        workspaceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workspaceRootURL)
    }

    @Test
    func testImportStopsWhenTheNewSessionCannotBeSaved() async throws {
        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("meeting.mp3")
        let probed = LockedValue<Bool>(false)
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                probed.set(true)
                return AudioImportProbeResult(title: "meeting", originalFileName: "meeting.mp3", originalFormat: "mp3", duration: 42)
            },
            readChannelSamples: { _ in DecodedAudio(channels: [[0.1]], sampleRate: 48_000) },
            writeMonoAAC: { _, _ in },
            retranscribe: { _, _, _, _ in },
            saveContext: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        await #expect(throws: AudioImportError.self) {
            try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)
        }
        #expect(probed.get() == false)
        #expect(fetchImportedSession() == nil)
    }

    @Test
    func testImportAudioSuccessfulMonoImport() async throws {
        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("meeting.mp3")

        let capturedWrittenSamples = LockedValue<[Float]>([])
        let capturedOutputURL = LockedValue<URL?>(nil)
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(
                    title: "meeting",
                    originalFileName: "meeting.mp3",
                    originalFormat: "mp3",
                    duration: 42
                )
            },
            readChannelSamples: { _ in
                DecodedAudio(channels: [[0.1, -0.2, 0.4]], sampleRate: 48_000)
            },
            writeMonoAAC: { samples, outputURL in
                capturedWrittenSamples.set(samples)
                capturedOutputURL.set(outputURL)
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { sessionID, modelContainer, _, _ in
                Self.updateImportedSession(id: sessionID, in: modelContainer) { session in
                    session.status = .done
                }
            }
        )

        try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        let imported = try #require(fetchImportedSession())
        #expect(imported.title == "meeting")
        #expect(imported.originalFileName == "meeting.mp3")
        #expect(imported.originalFormat == "mp3")
        #expect(abs(imported.duration - 42) < 0.001)
        #expect(capturedWrittenSamples.get() == [0.1, -0.2, 0.4])
        #expect(imported.mixdownURL == capturedOutputURL.get()?.path)
        #expect(imported.status == .done)
        #expect(imported.mixdownURL?.contains("/imports/meeting at ") == true)
    }

    @Test
    func testImportAudioStereoDownmixAveragesChannels() async throws {
        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("stereo.wav")

        let capturedWrittenSamples = LockedValue<[Float]>([])
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(
                    title: "stereo",
                    originalFileName: "stereo.wav",
                    originalFormat: "wav",
                    duration: 10
                )
            },
            readChannelSamples: { _ in
                DecodedAudio(
                    channels: [
                        [0.4, 0.2, -0.4],
                        [0.2, -0.2, 0.4]
                    ],
                    sampleRate: 48_000
                )
            },
            writeMonoAAC: { samples, outputURL in
                capturedWrittenSamples.set(samples)
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { _, _, _, _ in
            }
        )

        try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        let written = capturedWrittenSamples.get()
        #expect(written.count == 3)
        #expect(abs(written[0] - 0.3) < 0.0001)
        #expect(abs(written[1] - 0.0) < 0.0001)
        #expect(abs(written[2] - 0.0) < 0.0001)
    }

    @Test
    func testImportAudioCorruptFileSetsErrorStatus() async throws {
        enum CorruptError: LocalizedError {
            case corrupt
            var errorDescription: String? { "Corrupt audio file" }
        }

        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("corrupt.mp3")
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(
                    title: "corrupt",
                    originalFileName: "corrupt.mp3",
                    originalFormat: "mp3",
                    duration: 0
                )
            },
            readChannelSamples: { _ in
                throw CorruptError.corrupt
            }
        )

        try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        let imported = try #require(fetchImportedSession())
        if case .error(let message) = imported.status {
            #expect(message == "Corrupt audio file")
        } else {
            Issue.record("Expected error status for corrupt file")
        }
    }

    @Test
    func testImportAudioMissingFileSetsErrorStatus() async throws {
        enum MissingError: LocalizedError {
            case missing
            var errorDescription: String? { "Audio file not found" }
        }

        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("missing.wav")
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(
                    title: "missing",
                    originalFileName: "missing.wav",
                    originalFormat: "wav",
                    duration: 0
                )
            },
            readChannelSamples: { _ in
                throw MissingError.missing
            }
        )

        try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        let imported = try #require(fetchImportedSession())
        if case .error(let message) = imported.status {
            #expect(message == "Audio file not found")
        } else {
            Issue.record("Expected error status for missing file")
        }
    }

    @Test
    func testImportAudioFallsBackToMixdownServiceForSandboxDecodeError() async throws {
        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("sandboxed.mp3")

        let fallbackCalled = LockedValue(false)
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(
                    title: "sandboxed",
                    originalFileName: "sandboxed.mp3",
                    originalFormat: "mp3",
                    duration: 5
                )
            },
            readChannelSamples: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: 0)
            },
            mixToMonoM4A: { _, outputURL in
                fallbackCalled.set(true)
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { sessionID, modelContainer, _, _ in
                Self.updateImportedSession(id: sessionID, in: modelContainer) { session in
                    session.status = .done
                }
            }
        )

        try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        let imported = try #require(fetchImportedSession())
        #expect(fallbackCalled.get())
        #expect(imported.status == .done)
        #expect(imported.mixdownURL != nil)
        #expect(imported.mixdownURL?.hasSuffix("recording.m4a") == true)
    }

    @Test
    func testImportConvertsDecodedSamplesToOutputRate() async throws {
        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("cd-rate.wav")

        let capturedCount = LockedValue(0)
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(title: "cd-rate", originalFileName: "cd-rate.wav", originalFormat: "wav", duration: 10)
            },
            readChannelSamples: { _ in
                DecodedAudio(channels: [Array(repeating: 0.1, count: 441_000)], sampleRate: 44_100)
            },
            writeMonoAAC: { samples, outputURL in
                capturedCount.set(samples.count)
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { _, _, _, _ in }
        )

        try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        #expect(abs(capturedCount.get() - 480_000) <= Self.converterBlockFrames)
    }

    @Test(
        .enabled(if: AudioIOAvailability.isAvailable, AudioIOAvailability.unavailableReason),
        arguments: [16_000.0, 44_100.0, 48_000.0]
    )
    func testImportKeepsDurationAndPitchThroughDirectRead(sourceRate: Double) async throws {
        let output = try await importTone(sourceRate: sourceRate, forceFallback: false)
        #expect(abs(output.duration - Self.toneSeconds) <= Double(Self.converterBlockFrames) / AudioMixdownService.outputSampleRate)
        #expect(abs(output.frequency - Self.toneHz) < 5)
    }

    @Test(
        .enabled(if: AudioIOAvailability.isAvailable, AudioIOAvailability.unavailableReason),
        arguments: [16_000.0, 44_100.0, 48_000.0]
    )
    func testImportKeepsDurationAndPitchThroughFallback(sourceRate: Double) async throws {
        let output = try await importTone(sourceRate: sourceRate, forceFallback: true)
        #expect(abs(output.duration - Self.toneSeconds) <= Double(Self.converterBlockFrames) / AudioMixdownService.outputSampleRate)
        #expect(abs(output.frequency - Self.toneHz) < 5)
    }

    // MARK: - Real-file helpers

    private static let converterBlockFrames = 4_096
    private static let toneSeconds = 10.0
    private static let toneHz = 440.0

    /// Imports a 10-second 440 Hz tone written at `sourceRate` and returns the duration and
    /// frequency of the `recording.m4a` the import produced.
    private func importTone(sourceRate: Double, forceFallback: Bool) async throws -> (duration: Double, frequency: Double) {
        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("tone-\(Int(sourceRate)).wav")
        try writeTone(to: inputURL, sampleRate: sourceRate)

        let reader = AudioChannelReader()
        let service = AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(title: "tone", originalFileName: "tone.wav", originalFormat: "wav", duration: Self.toneSeconds)
            },
            readChannelSamples: { url in
                if forceFallback {
                    throw NSError(domain: NSCocoaErrorDomain, code: 0)
                }
                return try reader.read(url: url)
            },
            retranscribe: { _, _, _, _ in }
        )

        try await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        let imported = try #require(fetchImportedSession())
        let outputPath = try #require(imported.mixdownURL)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: outputPath))
        let samples = try readMono(file)
        let rate = file.processingFormat.sampleRate
        return (Double(file.length) / rate, zeroCrossingFrequency(samples, sampleRate: rate))
    }

    private func writeTone(to url: URL, sampleRate: Double) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let total = Int(sampleRate * Self.toneSeconds)
        var index = 0
        while index < total {
            let count = min(4_096, total - index)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            let channel = try #require(buffer.int16ChannelData)[0]
            buffer.frameLength = AVAudioFrameCount(count)
            for offset in 0..<count {
                let phase = 2 * Double.pi * Self.toneHz * Double(index + offset) / sampleRate
                channel[offset] = Int16(sin(phase) * 0.5 * Double(Int16.max))
            }
            try file.write(from: buffer)
            index += count
        }
    }

    private func readMono(_ file: AVAudioFile) throws -> [Float] {
        var samples: [Float] = []
        while file.framePosition < file.length {
            let count = AVAudioFrameCount(min(Int64(4_096), file.length - file.framePosition))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            let channel = try #require(buffer.floatChannelData)[0]
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }

    /// Frequency of a pure tone from its rising zero crossings, measured over the middle of the
    /// file so encoder priming at either end does not count.
    private func zeroCrossingFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        let start = samples.count / 4
        let end = samples.count * 3 / 4
        guard end > start + 1 else { return 0 }
        var crossings = 0
        for index in (start + 1)..<end where samples[index - 1] < 0 && samples[index] >= 0 {
            crossings += 1
        }
        return Double(crossings) / (Double(end - start) / sampleRate)
    }

    private func fetchImportedSession() -> ImportedSession? {
        let verifyContext = ModelContext(container)
        var descriptor = FetchDescriptor<ImportedSession>()
        descriptor.fetchLimit = 1
        return try? verifyContext.fetch(descriptor).first
    }
}
