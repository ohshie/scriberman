import Foundation
import SwiftData
import Testing
@testable import Scriberman

final class RecordingServiceTests {
    private func fetchRecordingSession(id: UUID, from context: ModelContext) throws -> RecordingSession {
        var descriptor = FetchDescriptor<RecordingSession>()
        descriptor.fetchLimit = 1_000
        return try #require(context.fetch(descriptor).first(where: { $0.id == id }))
    }

    @Test

    func testStartRecordingUsesTmpFolderMicPath() {
        let workspace = makeWorkspace()
        let urls = RecordingService.recordingFileURLs(in: workspace)

        #expect(urls.mic.path.hasSuffix("/recordings/tmp/mic.wav"))
        #expect(urls.app.path.hasSuffix("/recordings/tmp/app.wav"))
    }

    @Test

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

        #expect(!(FileManager.default.fileExists(atPath: workspace.tmpRecordingURL.path)))
        #expect(FileManager.default.fileExists(atPath: result.mic.path))
        #expect(folderName.range(of: expectedPattern, options: .regularExpression) != nil)
    }

    @Test

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

        #expect(result.mic.path.hasSuffix("/recordings/\(folderName)/mic.wav"))
        #expect(!(result.mic.path.contains("/recordings/tmp/")))
    }

    @Test

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

        #expect(result.mic.path == workspace.recordingsURL.appendingPathComponent("\(folderName)/mic.wav").path)
        #expect(result.app?.path == workspace.recordingsURL.appendingPathComponent("\(folderName)/app.wav").path)
    }

    @Test

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
        let persisted = try fetchRecordingSession(id: sessionID, from: context)
        #expect(persisted.mixdownURL == nil)
        #expect(persisted.status == .recorded)
    }

    @Test

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
        #expect(result == nil)
    }

    @Test

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
        #expect(hostTimes.mic == 1_000)
        #expect(hostTimes.app == 3_000)
    }

    @Test

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
        #expect(sessionID != nil)
        let ctx = ModelContext(container)
        let fetched = try fetchRecordingSession(id: try #require(sessionID), from: ctx)
        #expect(fetched.title == customTitle)
    }

    @Test

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
        #expect(sessionID != nil)
        let ctx = ModelContext(container)
        let fetched = try fetchRecordingSession(id: try #require(sessionID), from: ctx)
        #expect(fetched.title.hasPrefix("Recording "))
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
