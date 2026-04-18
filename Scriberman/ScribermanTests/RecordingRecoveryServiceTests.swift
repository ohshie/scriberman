import Foundation
import SwiftData
import Testing
@testable import Scriberman

private actor CallTracker {
    var called = false
    func markCalled() { called = true }
}

final class RecordingRecoveryServiceTests {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func makeSession(
        micAudioURL: String = "/tmp/mic.wav",
        status: RecordingStatus = .recorded,
        mixdownURL: String? = nil,
        mixdownAttemptCount: Int = 0
    ) -> RecordingSession {
        let session = RecordingSession(
            createdAt: .now,
            duration: 10,
            micAudioURL: micAudioURL,
            mixdownURL: mixdownURL,
            title: "Test",
            status: status,
            mixdownAttemptCount: mixdownAttemptCount
        )
        return session
    }

    // MARK: - 4.3: Exclude .recording sessions

    @Test
    func testSweepSkipsSessionsInRecordingStatus() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(status: .recording)
        context.insert(session)
        try context.save()

        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let tracker = CallTracker()
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _ in await tracker.markCalled() }
        )

        await service.sweepIncompleteSessions()

        #expect(!(await tracker.called))
        let fetched = try context.fetch(FetchDescriptor<RecordingSession>())
        #expect(fetched.first?.status == .recording)
    }

    // MARK: - 4.1 + 4.2: Retry boundedness and .error transition

    @Test
    func testSweepSkipsSessionsWithExistingMixdownURL() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(mixdownURL: "/tmp/recording.m4a")
        context.insert(session)
        try context.save()

        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let tracker = CallTracker()
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _ in await tracker.markCalled() }
        )

        await service.sweepIncompleteSessions()

        #expect(!(await tracker.called))
    }

    @Test
    func testSuccessfulRecoverySetsStatusAndMixdownURL() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        FileManager.default.createFile(atPath: micPath, contents: Data())

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: micPath)
        context.insert(session)
        try context.save()
        let sessionID = session.id

        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _ in }
        )

        await service.sweepIncompleteSessions()

        let readContext = ModelContext(container)
        var descriptor = FetchDescriptor<RecordingSession>()
        descriptor.fetchLimit = 100
        let fetched = try readContext.fetch(descriptor)
        let recovered = try #require(fetched.first(where: { $0.id == sessionID }))
        #expect(recovered.mixdownURL != nil)
        #expect(recovered.status == .recorded)
    }

    @Test
    func testFailedMixdownIncrementsAttemptCount() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        FileManager.default.createFile(atPath: micPath, contents: Data())

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: micPath, mixdownAttemptCount: 0)
        context.insert(session)
        try context.save()
        let sessionID = session.id

        struct MixdownError: Error {}
        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _ in throw MixdownError() }
        )

        await service.sweepIncompleteSessions()

        let readContext = ModelContext(container)
        var descriptor = FetchDescriptor<RecordingSession>()
        descriptor.fetchLimit = 100
        let fetched = try readContext.fetch(descriptor)
        let result = try #require(fetched.first(where: { $0.id == sessionID }))
        #expect(result.mixdownAttemptCount == 1)
        #expect(result.mixdownURL == nil)
    }

    @Test
    func testSessionTransitionsToErrorAfterMaxAttempts() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        FileManager.default.createFile(atPath: micPath, contents: Data())

        let container = try makeContainer()
        let context = ModelContext(container)
        // One attempt away from max
        let session = makeSession(micAudioURL: micPath, mixdownAttemptCount: RecordingRecoveryService.maxMixdownAttempts - 1)
        context.insert(session)
        try context.save()
        let sessionID = session.id

        struct MixdownError: Error {}
        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _ in throw MixdownError() }
        )

        await service.sweepIncompleteSessions()

        let readContext = ModelContext(container)
        var descriptor = FetchDescriptor<RecordingSession>()
        descriptor.fetchLimit = 100
        let fetched = try readContext.fetch(descriptor)
        let result = try #require(fetched.first(where: { $0.id == sessionID }))
        #expect(result.mixdownAttemptCount == RecordingRecoveryService.maxMixdownAttempts)
        if case .error(let message) = result.status {
            #expect(message.contains("\(RecordingRecoveryService.maxMixdownAttempts)"))
        } else {
            Issue.record("Expected .error status, got \(result.status)")
        }
    }

    @Test
    func testAlreadyExhaustedSessionIsMarkedErrorWithoutCallingMixdown() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        FileManager.default.createFile(atPath: micPath, contents: Data())

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(
            micAudioURL: micPath,
            mixdownAttemptCount: RecordingRecoveryService.maxMixdownAttempts
        )
        context.insert(session)
        try context.save()
        let sessionID = session.id

        let tracker = CallTracker()
        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _ in await tracker.markCalled() }
        )

        await service.sweepIncompleteSessions()

        #expect(!(await tracker.called))
        let readContext = ModelContext(container)
        var descriptor = FetchDescriptor<RecordingSession>()
        descriptor.fetchLimit = 100
        let fetched = try readContext.fetch(descriptor)
        let result = try #require(fetched.first(where: { $0.id == sessionID }))
        if case .error = result.status {
            // correct
        } else {
            Issue.record("Expected .error status, got \(result.status)")
        }
    }

    // MARK: - Helpers

    private func makeWorkspace() -> Workspace {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Workspace(rootURL: url)
    }
}
