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
            for: RecordingSession.self, ImportedSession.self,
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
                [[0.1, -0.2, 0.4]]
            },
            writeMonoAAC: { samples, outputURL in
                capturedWrittenSamples.set(samples)
                capturedOutputURL.set(outputURL)
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { sessionID, modelContainer, _ in
                Self.updateImportedSession(id: sessionID, in: modelContainer) { session in
                    session.status = .done
                }
            }
        )

        await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

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
                [
                    [0.4, 0.2, -0.4],
                    [0.2, -0.2, 0.4]
                ]
            },
            writeMonoAAC: { samples, outputURL in
                capturedWrittenSamples.set(samples)
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { _, _, _ in
            }
        )

        await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

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

        await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

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

        await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

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
            retranscribe: { sessionID, modelContainer, _ in
                Self.updateImportedSession(id: sessionID, in: modelContainer) { session in
                    session.status = .done
                }
            }
        )

        await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)

        let imported = try #require(fetchImportedSession())
        #expect(fallbackCalled.get())
        #expect(imported.status == .done)
        #expect(imported.mixdownURL != nil)
        #expect(imported.mixdownURL?.hasSuffix("recording.m4a") == true)
    }

    private func fetchImportedSession() -> ImportedSession? {
        let verifyContext = ModelContext(container)
        var descriptor = FetchDescriptor<ImportedSession>()
        descriptor.fetchLimit = 1
        return try? verifyContext.fetch(descriptor).first
    }
}
