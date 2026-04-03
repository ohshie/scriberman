import Foundation
import SwiftData
import XCTest
@testable import Scriberman

final class AudioImportServiceTests: XCTestCase {
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

    private var container: ModelContainer!
    private var context: ModelContext!
    private var workspaceRootURL: URL!

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

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        workspaceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspaceRootURL {
            try? FileManager.default.removeItem(at: workspaceRootURL)
        }
        workspaceRootURL = nil
        context = nil
        container = nil
        try super.tearDownWithError()
    }

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

        let imported = try XCTUnwrap(fetchImportedSession())
        XCTAssertEqual(imported.title, "meeting")
        XCTAssertEqual(imported.originalFileName, "meeting.mp3")
        XCTAssertEqual(imported.originalFormat, "mp3")
        XCTAssertEqual(imported.duration, 42, accuracy: 0.001)
        XCTAssertEqual(capturedWrittenSamples.get(), [0.1, -0.2, 0.4])
        XCTAssertEqual(imported.mixdownURL, capturedOutputURL.get()?.path)
        XCTAssertEqual(imported.status, .done)
        XCTAssertTrue(imported.mixdownURL?.contains("/imports/meeting at ") == true)
    }

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
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(written[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(written[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(written[2], 0.0, accuracy: 0.0001)
    }

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

        let imported = try XCTUnwrap(fetchImportedSession())
        if case .error(let message) = imported.status {
            XCTAssertEqual(message, "Corrupt audio file")
        } else {
            XCTFail("Expected error status for corrupt file")
        }
    }

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

        let imported = try XCTUnwrap(fetchImportedSession())
        if case .error(let message) = imported.status {
            XCTAssertEqual(message, "Audio file not found")
        } else {
            XCTFail("Expected error status for missing file")
        }
    }

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

        let imported = try XCTUnwrap(fetchImportedSession())
        XCTAssertTrue(fallbackCalled.get())
        XCTAssertEqual(imported.status, .done)
        XCTAssertNotNil(imported.mixdownURL)
        XCTAssertTrue(imported.mixdownURL?.hasSuffix("recording.m4a") == true)
    }

    private func fetchImportedSession() -> ImportedSession? {
        let verifyContext = ModelContext(container)
        var descriptor = FetchDescriptor<ImportedSession>()
        descriptor.fetchLimit = 1
        return try? verifyContext.fetch(descriptor).first
    }
}
