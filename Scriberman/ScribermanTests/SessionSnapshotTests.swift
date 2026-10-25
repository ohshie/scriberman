import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
struct SessionSnapshotTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let folder: URL

    init() throws {
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test
    func testASnapshotWrittenToAFolderReadsBackEqual() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = RecordingSession(duration: 12, micAudioURL: folder.appendingPathComponent("mic.wav").path, title: "A")
        context.insert(session)
        session.transcriptSegments = [
            RecordingTranscriptSegment(speakerId: "S1", text: "Hello", startTime: 0, endTime: 1, audioSource: .app)
        ]
        let deletedAt = Date(timeIntervalSinceReferenceDate: 800_000_000.25)
        let snapshot = SessionSnapshot(recording: session, originalFolder: folder, deletedAt: deletedAt)

        try snapshot.write(into: folder)

        #expect(try SessionSnapshot.read(from: folder) == snapshot)
        #expect(SessionSnapshot.exists(in: folder))
    }

    @Test
    func testReadingAFolderWithNoSnapshotThrows() {
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: (any Error).self) { try SessionSnapshot.read(from: folder) }
        #expect(!SessionSnapshot.exists(in: folder))
    }

    @Test
    func testRemovingTheSnapshotLeavesTheRestOfTheFolder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("mic.wav"))
        let session = RecordingSession(duration: 1, micAudioURL: folder.appendingPathComponent("mic.wav").path, title: "A")
        try SessionSnapshot(recording: session, originalFolder: folder, deletedAt: .now).write(into: folder)

        try SessionSnapshot.remove(from: folder)

        #expect(!SessionSnapshot.exists(in: folder))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.wav").path))
    }
}

@MainActor
struct HoldingFolderTests {
    private let workspace: Workspace

    init() throws {
        workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.importsURL, withIntermediateDirectories: true)
    }

    @Test
    func testTheHoldingFolderIsHiddenAtTheWorkspaceRoot() {
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let holding = HoldingFolder(workspace: workspace)

        #expect(holding.url.deletingLastPathComponent().standardizedFileURL == workspace.rootURL.standardizedFileURL)
        #expect(holding.url.lastPathComponent.hasPrefix("."))
    }

    @Test
    func testHoldingMovesTheFolderToASubfolderNamedByTheSessionID() throws {
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let holding = HoldingFolder(workspace: workspace)
        let folder = workspace.recordingsURL.appendingPathComponent("Recording A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("mic.wav"))
        let id = UUID()

        try holding.hold(folder, sessionID: id)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(holding.heldFolder(for: id).lastPathComponent == id.uuidString)
        #expect(FileManager.default.fileExists(atPath: holding.heldFolder(for: id).appendingPathComponent("mic.wav").path))
    }

    @Test
    func testReleasingMovesTheHeldFolderBack() throws {
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let holding = HoldingFolder(workspace: workspace)
        let folder = workspace.recordingsURL.appendingPathComponent("Recording A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("mic.wav"))
        let id = UUID()
        try holding.hold(folder, sessionID: id)

        try holding.release(sessionID: id, to: folder)

        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.wav").path))
        #expect(!FileManager.default.fileExists(atPath: holding.heldFolder(for: id).path))
    }

    @Test
    func testHoldingRefusesAFolderOutsideTheSessionAreas() throws {
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let holding = HoldingFolder(workspace: workspace)
        let outside = workspace.rootURL.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try holding.hold(outside, sessionID: UUID()) }
        #expect(throws: (any Error).self) { try holding.hold(workspace.recordingsURL, sessionID: UUID()) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func testReleasingRefusesAnOccupiedOriginalPath() throws {
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let holding = HoldingFolder(workspace: workspace)
        let folder = workspace.recordingsURL.appendingPathComponent("Recording A", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        try holding.hold(folder, sessionID: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { try holding.release(sessionID: id, to: folder) }
        #expect(FileManager.default.fileExists(atPath: holding.heldFolder(for: id).path))
    }
}
