import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// Deleting an imported session that has not finished importing or transcribing: for good at once,
/// after the confirmation, with its import stopped first.
@MainActor
final class UnfinishedImportDeletionTests {
    /// A value several tasks set and read.
    private final class Locked<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        var current: Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private let workspace: Workspace
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext
    private let undoManager = UndoManager.forTests()
    private let sessionJobs = SessionJobs()
    private var failSaves = false
    private lazy var coordinator = SessionDeletionCoordinator(
        workspaceService: workspaceService,
        saveContext: { [unowned self] context in
            if failSaves { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        },
        announce: { _ in },
        startAccess: { _ in false },
        stopAccess: { _ in },
        sessionJobs: sessionJobs
    )

    init() throws {
        workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.importsURL, withIntermediateDirectories: true)
        workspaceService.currentWorkspaceResult = workspace
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    deinit {
        try? FileManager.default.removeItem(at: workspace.rootURL)
    }

    // MARK: - Fixtures

    private var inputURL: URL { workspace.rootURL.appendingPathComponent("meeting.mp3") }

    /// An import whose conversion and transcription are the given closures.
    private func makeImportService(
        writeMonoAAC: @escaping AudioImportService.WriteMonoAAC = { _, outputURL in
            FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
        },
        retranscribe: @escaping AudioImportService.Retranscribe = { _, _, _, _ in }
    ) -> AudioImportService {
        AudioImportService(
            retranscriptionService: RetranscriptionService(transcriptionService: TranscriptionService()),
            probeAudio: { _ in
                AudioImportProbeResult(title: "meeting", originalFileName: "meeting.mp3", originalFormat: "mp3", duration: 42)
            },
            readChannelSamples: { _ in DecodedAudio(channels: [[0.1, 0.2]], sampleRate: 48_000) },
            writeMonoAAC: writeMonoAAC,
            retranscribe: retranscribe,
            sessionJobs: sessionJobs
        )
    }

    /// Starts `service` importing and returns the task running it.
    private func startImport(_ service: AudioImportService) -> Task<Void, Never> {
        let workspace = workspace
        let container = container
        let inputURL = inputURL
        return Task.detached {
            try? await service.importAudio(from: inputURL, workspace: workspace, modelContainer: container)
        }
    }

    /// Waits until `condition` holds, failing the test after a few seconds.
    private func waitUntil(_ condition: () throws -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async rethrows {
        for _ in 0..<500 {
            if try condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting", sourceLocation: sourceLocation)
    }

    /// The imported session in the test's context, fetched afresh.
    private func liveImportedSession() throws -> ImportedSession? {
        try context.fetch(FetchDescriptor<ImportedSession>()).first
    }

    private func storedImportedSessions() throws -> [ImportedSession] {
        try ModelContext(container).fetch(FetchDescriptor<ImportedSession>())
    }

    /// The session folders in `imports/`.
    private func importFolders() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: workspace.importsURL, includingPropertiesForKeys: nil)
    }

    private func makeFolder(named name: String = "Imported A") throws -> URL {
        let folder = workspace.importsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: folder.appendingPathComponent("recording.m4a"))
        return folder
    }

    private func makeImported(mixdownIn folder: URL?, status: RecordingStatus) throws -> ImportedSession {
        let session = ImportedSession(
            duration: 60,
            mixdownURL: folder?.appendingPathComponent("recording.m4a").path,
            title: "A",
            originalFileName: "A.mp3",
            originalFormat: "mp3",
            status: status
        )
        context.insert(session)
        try context.save()
        return session
    }

    @discardableResult
    private func confirmDelete(_ session: ImportedSession) async -> JobsViewModel.DeletionResult {
        await coordinator.deleteAfterConfirmation(session, context: context, undoManager: undoManager)
    }

    /// Nothing was held and nothing can be undone.
    private func expectNothingHeld(sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(await coordinator.heldSessions().isEmpty, sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: HoldingFolder(workspace: workspace).url.path), sourceLocation: sourceLocation)
        #expect(!undoManager.canUndo, sourceLocation: sourceLocation)
    }

    // MARK: - A running import

    @Test
    func testDeletingAConvertingImportCancelsItAndRemovesTheFolderItCreated() async throws {
        let conversionCancelled = Locked(false)
        let service = makeImportService(writeMonoAAC: { _, outputURL in
            FileManager.default.createFile(atPath: outputURL.path, contents: Data("partial".utf8))
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                conversionCancelled.set(true)
                throw error
            }
        })
        let importTask = startImport(service)
        try await waitUntil { try importFolders().count == 1 }
        let session = try #require(try liveImportedSession())
        #expect(session.status == .converting)
        #expect(session.mixdownURL == nil)
        #expect(!SessionDeletionCoordinator.canHold(session))

        let result = await confirmDelete(session)
        await importTask.value

        #expect(result == .deleted)
        #expect(conversionCancelled.current)
        #expect(try storedImportedSessions().isEmpty)
        #expect(try importFolders().isEmpty)
        await expectNothingHeld()
    }

    @Test
    func testAConversionStepThatCannotBeInterruptedIsWaitedOutAndNothingFollowsIt() async throws {
        let release = Locked(false)
        let transcribed = Locked(false)
        let service = makeImportService(
            writeMonoAAC: { _, outputURL in
                // Ignores cancellation, as an export already running does.
                while !release.current {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
            },
            retranscribe: { _, _, _, _ in transcribed.set(true) }
        )
        let importTask = startImport(service)
        try await waitUntil { try importFolders().count == 1 }
        let session = try #require(try liveImportedSession())

        let deletion = Task { await confirmDelete(session) }
        await waitUntil { coordinator.isRemoving(session.id) }
        try? await Task.sleep(for: .milliseconds(50))
        // Still converting: the delete waits for it.
        #expect(try importFolders().count == 1)
        #expect(try storedImportedSessions().count == 1)
        release.set(true)
        let result = await deletion.value
        await importTask.value

        #expect(result == .deleted)
        #expect(!transcribed.current)
        #expect(try storedImportedSessions().isEmpty)
        #expect(try importFolders().isEmpty)
        await expectNothingHeld()
    }

    @Test
    func testDeletingAnImportWhileItTranscribesCancelsTheTranscription() async throws {
        let transcriptionCancelled = Locked(false)
        let service = makeImportService(retranscribe: { _, _, _, _ in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                transcriptionCancelled.set(true)
            }
        })
        let importTask = startImport(service)
        try await waitUntil { try storedImportedSessions().first?.status == .transcribing }
        let session = try #require(try liveImportedSession())
        #expect(!SessionDeletionCoordinator.canHold(session))

        let result = await confirmDelete(session)
        await importTask.value

        #expect(result == .deleted)
        #expect(transcriptionCancelled.current)
        #expect(try storedImportedSessions().isEmpty)
        #expect(try importFolders().isEmpty)
        await expectNothingHeld()
    }

    @Test
    func testCancellingTheConfirmationLeavesTheImportRunning() async throws {
        let release = Locked(false)
        let service = makeImportService(writeMonoAAC: { _, outputURL in
            while !release.current {
                try? await Task.sleep(for: .milliseconds(5))
            }
            FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
        }, retranscribe: { sessionID, container, _, _ in
            let context = ModelContext(container)
            try? ImportedSession.fetch(id: sessionID, in: context)?.status = .done
            try? context.save()
        })
        let importTask = startImport(service)
        try await waitUntil { try importFolders().count == 1 }
        let session = try #require(try liveImportedSession())
        // The confirmation is asked, then cancelled: the coordinator is never called.
        #expect(!SessionDeletionCoordinator.canHold(session))

        release.set(true)
        await importTask.value

        let stored = try #require(try storedImportedSessions().first)
        #expect(stored.status == .done)
        let mixdown = try #require(stored.mixdownURL)
        #expect(FileManager.default.fileExists(atPath: mixdown))
        await expectNothingHeld()
    }

    @Test
    func testAnImportThatFinishesWhileTheConfirmationIsOpenIsHeldOnConfirm() async throws {
        let release = Locked(false)
        let service = makeImportService(writeMonoAAC: { _, outputURL in
            while !release.current {
                try? await Task.sleep(for: .milliseconds(5))
            }
            FileManager.default.createFile(atPath: outputURL.path, contents: Data("aac".utf8))
        }, retranscribe: { sessionID, container, _, _ in
            let context = ModelContext(container)
            try? ImportedSession.fetch(id: sessionID, in: context)?.status = .done
            try? context.save()
        })
        let importTask = startImport(service)
        try await waitUntil { try importFolders().count == 1 }
        let session = try #require(try liveImportedSession())
        // The confirmation opens for an unfinished import ...
        #expect(!SessionDeletionCoordinator.canHold(session))

        // ... which finishes before the user confirms.
        release.set(true)
        await importTask.value
        let settled = try #require(try ImportedSession.fetch(id: session.id, in: ModelContext(container)))
        session.mixdownURL = settled.mixdownURL
        session.status = settled.status
        #expect(SessionDeletionCoordinator.canHold(session))

        let result = await confirmDelete(session)

        #expect(result == .deleted)
        #expect(try storedImportedSessions().isEmpty)
        #expect(try importFolders().isEmpty)
        #expect(await coordinator.heldSessions().map(\.sessionID) == [session.id])
        #expect(undoManager.canUndo)
    }

    @Test
    func testAnImportThatFailedThisRunHasItsFolderRemoved() async throws {
        let service = makeImportService(writeMonoAAC: { _, _ in throw URLError(.cannotDecodeContentData) })
        await startImport(service).value
        let session = try #require(try liveImportedSession())
        #expect(session.mixdownURL == nil)
        guard case .error = session.status else {
            Issue.record("Expected the import to fail, got \(session.status)")
            return
        }
        #expect(try importFolders().count == 1)

        let result = await confirmDelete(session)

        #expect(result == .deleted)
        #expect(try storedImportedSessions().isEmpty)
        #expect(try importFolders().isEmpty)
        await expectNothingHeld()
    }

    // MARK: - No running import

    @Test(arguments: [RecordingStatus.converting, .transcribing, .retranscribing])
    func testAnUnfinishedSessionWithAMixdownIsDeletedWithItsFolder(status: RecordingStatus) async throws {
        let folder = try makeFolder()
        let session = try makeImported(mixdownIn: folder, status: status)
        #expect(!SessionDeletionCoordinator.canHold(session))

        let result = await confirmDelete(session)

        #expect(result == .deleted)
        #expect(try storedImportedSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await expectNothingHeld()
    }

    @Test
    func testAnImportThatFailedInAnEarlierRunHasItsRecordDeletedAndItsFolderLeft() async throws {
        let folder = try makeFolder()
        let session = try makeImported(mixdownIn: nil, status: .error("boom"))

        let result = await confirmDelete(session)

        #expect(result == .deleted)
        #expect(try storedImportedSessions().isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        await expectNothingHeld()
    }

    @Test
    func testAFolderThatCannotBeRemovedIsReportedAsLeft() async throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let session = try makeImported(mixdownIn: outside, status: .transcribing)

        let result = await confirmDelete(session)

        guard case .filesLeft(let left) = result else {
            Issue.record("Expected filesLeft, got \(result)")
            return
        }
        #expect(left.standardizedFileURL.path == outside.standardizedFileURL.path)
        #expect(try storedImportedSessions().isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        await expectNothingHeld()
    }

    @Test
    func testAFailedSaveKeepsTheRecordAndItsFolder() async throws {
        let folder = try makeFolder()
        let session = try makeImported(mixdownIn: folder, status: .transcribing)
        failSaves = true

        let result = await confirmDelete(session)

        guard case .saveFailed = result else {
            Issue.record("Expected saveFailed, got \(result)")
            return
        }
        #expect(try storedImportedSessions().map(\.id) == [session.id])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.m4a").path))
        await expectNothingHeld()
    }
}
