import Foundation
import SwiftData
import XCTest
@testable import Scriberman

@MainActor
final class AudioImportServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var workspaceRootURL: URL!

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

        var capturedWrittenSamples: [Float] = []
        var capturedOutputURL: URL?
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
                capturedWrittenSamples = samples
                capturedOutputURL = outputURL
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { session, _, context in
                session.status = .done
                try? context.save()
            }
        )

        await service.importAudio(from: inputURL, workspace: workspace, context: context)

        let imported = try XCTUnwrap(fetchImportedSession())
        XCTAssertEqual(imported.title, "meeting")
        XCTAssertEqual(imported.originalFileName, "meeting.mp3")
        XCTAssertEqual(imported.originalFormat, "mp3")
        XCTAssertEqual(imported.duration, 42, accuracy: 0.001)
        XCTAssertEqual(capturedWrittenSamples, [0.1, -0.2, 0.4])
        XCTAssertEqual(imported.mixdownURL, capturedOutputURL?.path)
        XCTAssertEqual(imported.status, .done)
        XCTAssertTrue(imported.mixdownURL?.contains("/imports/meeting at ") == true)
    }

    func testImportAudioStereoDownmixAveragesChannels() async throws {
        let workspace = Workspace(rootURL: workspaceRootURL)
        let inputURL = workspaceRootURL.appendingPathComponent("stereo.wav")

        var capturedWrittenSamples: [Float] = []
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
                capturedWrittenSamples = samples
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { _, _, _ in
            }
        )

        await service.importAudio(from: inputURL, workspace: workspace, context: context)

        XCTAssertEqual(capturedWrittenSamples.count, 3)
        XCTAssertEqual(capturedWrittenSamples[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(capturedWrittenSamples[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(capturedWrittenSamples[2], 0.0, accuracy: 0.0001)
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

        await service.importAudio(from: inputURL, workspace: workspace, context: context)

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

        await service.importAudio(from: inputURL, workspace: workspace, context: context)

        let imported = try XCTUnwrap(fetchImportedSession())
        if case .error(let message) = imported.status {
            XCTAssertEqual(message, "Audio file not found")
        } else {
            XCTFail("Expected error status for missing file")
        }
    }

    private func fetchImportedSession() -> ImportedSession? {
        var descriptor = FetchDescriptor<ImportedSession>()
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
