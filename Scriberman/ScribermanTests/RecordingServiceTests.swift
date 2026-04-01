import Foundation
import SwiftData
import XCTest
@testable import Scriberman

final class RecordingServiceTests: XCTestCase {
    func testStartRecordingUsesTmpFolderMicPath() {
        let workspace = makeWorkspace()
        let urls = RecordingService.recordingFileURLs(in: workspace)

        XCTAssertTrue(urls.mic.path.hasSuffix("/recordings/tmp/mic.wav"))
        XCTAssertTrue(urls.app.path.hasSuffix("/recordings/tmp/app.wav"))
    }

    func testStopRecordingPromotesTmpFolderToNamedFolderPattern() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000) // 2025-03-28 14:30 UTC
        let result = try RecordingService.promoteTmpRecordingFolder(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "12345678-a3"
        )

        let folderName = result.mic.deletingLastPathComponent().lastPathComponent
        let expectedPattern = #"^Recording [A-Z][a-z]{2} \d{2} at \d{2}-\d{2} [A-Za-z0-9]{2}$"#

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.tmpRecordingURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mic.path))
        XCTAssertNotNil(folderName.range(of: expectedPattern, options: .regularExpression))
    }

    func testStopRecordingMicPathUsesNamedFolderNotTmp() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000)
        let result = try RecordingService.promoteTmpRecordingFolder(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "abcdef12"
        )
        let folderName = RecordingService.folderName(createdAt: createdAt, recordingIdentifier: "abcdef12")

        XCTAssertTrue(result.mic.path.hasSuffix("/recordings/\(folderName)/mic.wav"))
        XCTAssertFalse(result.mic.path.contains("/recordings/tmp/"))
    }

    func testFolderBasedPathExpectationUsesNamedFolderMicFile() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))
        let tmpAppURL = workspace.tmpRecordingURL.appendingPathComponent("app.wav")
        _ = FileManager.default.createFile(atPath: tmpAppURL.path, contents: Data("app".utf8))

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000)
        let result = try RecordingService.promoteTmpRecordingFolder(
            in: workspace,
            createdAt: createdAt,
            recordingIdentifier: "11111111-a3"
        )
        let folderName = RecordingService.folderName(createdAt: createdAt, recordingIdentifier: "11111111-a3")

        XCTAssertEqual(result.mic.path, workspace.recordingsURL.appendingPathComponent("\(folderName)/mic.wav").path)
        XCTAssertEqual(result.app?.path, workspace.recordingsURL.appendingPathComponent("\(folderName)/app.wav").path)
    }

    func testMixdownFailureLeavesSessionMixdownURLNilAndStatusUnchanged() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container
        )

        let context = ModelContext(container)
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 12,
            micAudioURL: "/tmp/missing-mic.wav",
            mixdownURL: nil,
            title: "Session",
            status: .recorded
        )
        context.insert(session)
        try context.save()

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("recording.m4a")
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        await service.runMixdown(
            sessionID: session.id,
            micURL: URL(fileURLWithPath: "/tmp/does-not-exist-mic.wav"),
            appURL: nil,
            mixdownURL: outputURL,
            micStartHostTime: 1,
            appStartHostTime: nil
        )

        let sessionID = session.id
        var descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == sessionID })
        descriptor.fetchLimit = 1
        let persisted = try XCTUnwrap(context.fetch(descriptor).first)
        XCTAssertNil(persisted.mixdownURL)
        XCTAssertEqual(persisted.status, .recorded)
    }

    func testStopRecordingWhenNotRecordingReturnsNil() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container
        )

        let result = await service.stopRecording()
        XCTAssertNil(result)
    }

    func testCaptureHostTimesKeepsFirstObservedValues() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container
        )

        await service.captureMicStartHostTimeIfNeeded(1_000)
        await service.captureMicStartHostTimeIfNeeded(2_000)
        await service.captureAppStartHostTimeIfNeeded(3_000)
        await service.captureAppStartHostTimeIfNeeded(4_000)

        let hostTimes = await service.capturedHostTimes()
        XCTAssertEqual(hostTimes.mic, 1_000)
        XCTAssertEqual(hostTimes.app, 3_000)
    }

    func testStartRecordingWithCustomTitlePersistsTitle() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container
        )

        let customTitle = "My Custom Title"
        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))

        // Fake the recording state
        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: "test-id",
            recordingWorkspaceRootURL: workspace.rootURL,
            pendingTitle: customTitle
        )

        let sessionID = await service.stopRecording()
        XCTAssertNotNil(sessionID)
        let ctx = ModelContext(container)
        let predicate = #Predicate<RecordingSession> { $0.id == sessionID! }
        let fetched = try ctx.fetch(FetchDescriptor<RecordingSession>(predicate: predicate)).first
        XCTAssertEqual(fetched?.title, customTitle)
    }

    func testStopRecordingFallbacksToDefaultTitleWhenNoPendingTitle() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container
        )

        try FileManager.default.createDirectory(at: workspace.tmpRecordingURL, withIntermediateDirectories: true)
        let tmpMicURL = workspace.tmpRecordingURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: tmpMicURL.path, contents: Data("mic".utf8))

        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: "test-id-default",
            recordingWorkspaceRootURL: workspace.rootURL,
            pendingTitle: nil
        )

        let sessionID = await service.stopRecording()
        XCTAssertNotNil(sessionID)
        let ctx = ModelContext(container)
        let predicate = #Predicate<RecordingSession> { $0.id == sessionID! }
        let fetched = try ctx.fetch(FetchDescriptor<RecordingSession>(predicate: predicate)).first
        XCTAssertTrue(fetched?.title.hasPrefix("Recording ") ?? false)
    }

    private func makeWorkspace() -> Workspace {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return Workspace(rootURL: rootURL)
    }

    private func removeWorkspace(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
