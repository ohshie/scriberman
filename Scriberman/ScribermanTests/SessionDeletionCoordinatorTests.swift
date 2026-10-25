import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
final class SessionDeletionCoordinatorTests {
    private let workspace: Workspace
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext
    private let undoManager = UndoManager.forTests()
    /// Run by every save before it saves; throwing makes the save fail.
    private var beforeSave: (() throws -> Void)?
    private var announcements: [String] = []
    private var scopeEvents: [String] = []
    /// Run when the coordinator gives back the workspace's security scope.
    private var onStopAccess: (() -> Void)?
    private let deletedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private lazy var coordinator = makeCoordinator()

    init() throws {
        workspace = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        try FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.importsURL, withIntermediateDirectories: true)
        workspaceService.currentWorkspaceResult = workspace
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    deinit {
        for url in [workspace.rootURL, workspace.recordingsURL, HoldingFolder(workspace: workspace).url] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: workspace.rootURL)
    }

    private func makeCoordinator() -> SessionDeletionCoordinator {
        SessionDeletionCoordinator(
            workspaceService: workspaceService,
            saveContext: { [unowned self] context in
                try beforeSave?()
                try context.save()
            },
            now: { [deletedAt] in deletedAt },
            announce: { [unowned self] in announcements.append($0) },
            startAccess: { [unowned self] _ in
                scopeEvents.append("start")
                return true
            },
            stopAccess: { [unowned self] _ in
                onStopAccess?()
                scopeEvents.append("stop")
            }
        )
    }

    // MARK: - Fixtures

    private var holding: HoldingFolder { HoldingFolder(workspace: workspace) }

    private func makeFolder(named name: String = "Recording A") throws -> URL {
        let folder = workspace.recordingsURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["mic.wav", "app.wav", "recording.m4a", "mic.wav.timing", "screen.mov", "transcript.md"] {
            try Data("\(name) \(file)".utf8).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    private func makeRecording(in folder: URL, title: String = "A") throws -> RecordingSession {
        let session = RecordingSession(
            duration: 60,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            mixdownURL: folder.appendingPathComponent("recording.m4a").path,
            title: title,
            status: .done
        )
        context.insert(session)
        try context.save()
        return session
    }

    private func storedRecordings() throws -> [RecordingSession] {
        try ModelContext(container).fetch(FetchDescriptor<RecordingSession>())
    }

    private func contents(of folder: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try Data(contentsOf: folder.appendingPathComponent(name)))
        })
    }

    private func delete(_ session: RecordingSession, with undoManager: UndoManager? = nil) async -> JobsViewModel.DeletionResult {
        await coordinator.delete(session, context: context, undoManager: undoManager ?? self.undoManager)
    }

    private func undo(_ undoManager: UndoManager? = nil) async {
        (undoManager ?? self.undoManager).undo()
        await coordinator.waitUntilIdle()
    }

    private func redo(_ undoManager: UndoManager? = nil) async {
        (undoManager ?? self.undoManager).redo()
        await coordinator.waitUntilIdle()
    }

    private func makeTag(_ name: String) throws -> RecordingTag {
        let tag = RecordingTag(name: name, colorHex: "112233")
        context.insert(tag)
        try context.save()
        return tag
    }

    // MARK: - Delete

    @Test
    func testDeleteMovesTheFolderIntoHoldingWithASnapshotAndRemovesTheRecord() async throws {
        let folder = try makeFolder()
        let files = try contents(of: folder)
        let session = try makeRecording(in: folder)
        let id = session.id

        let result = await delete(session)

        #expect(result == .deleted)
        #expect(try storedRecordings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let held = holding.heldFolder(for: id)
        let snapshot = try SessionSnapshot.read(from: held)
        #expect(snapshot.originalFolderPath == folder.path)
        #expect(snapshot.deletedAt == deletedAt)
        var heldFiles = try contents(of: held)
        heldFiles.removeValue(forKey: SessionSnapshot.fileName)
        #expect(heldFiles == files)
    }

    @Test
    func testDeleteRegistersUndoNamedDeleteSessionAndAnnounces() async throws {
        let session = try makeRecording(in: try makeFolder())

        await delete(session)

        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == UndoActionName.deleteSession)
        #expect(undoManager.undoMenuItemTitle == "Undo Delete Session")
        #expect(announcements == ["Session deleted"])
    }

    @Test(arguments: ["Recording Mar 28 at 14-30 a3", "2026-03-28 14-30"])
    func testDeleteHoldsAFolderInEitherNameFormat(folderName: String) async throws {
        let folder = try makeFolder(named: folderName)
        let session = try makeRecording(in: folder)
        let id = session.id

        #expect(await delete(session) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
    }

    /// A session whose folder is already gone must still be deletable.
    @Test
    func testDeletingARecordingWhoseFolderIsGoneStillRemovesTheRecordAndCanBeUndone() async throws {
        let folder = workspace.recordingsURL.appendingPathComponent("Gone", isDirectory: true)
        let session = try makeRecording(in: folder)
        let id = session.id

        #expect(await delete(session) == .deleted)
        #expect(try storedRecordings().isEmpty)
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))

        await undo()

        #expect(try storedRecordings().map(\.id) == [id])
    }

    @Test
    func testRemovalObserversAreToldBeforeTheRecordGoes() async throws {
        let session = try makeRecording(in: try makeFolder())
        let id = session.id
        var told: [(UUID, Int)] = []
        let observation = coordinator.observeRemovals { [unowned self] removedID in
            told.append((removedID, (try? storedRecordings().count) ?? -1))
        }

        await delete(session)

        #expect(told.map(\.0) == [id])
        #expect(told.map(\.1) == [1])
        _ = observation
    }

    @Test
    func testARemovalObserverThatIsReleasedIsNotTold() async throws {
        let session = try makeRecording(in: try makeFolder())
        var told = 0
        var observation: SessionDeletionCoordinator.RemovalObservation? = coordinator.observeRemovals { _ in told += 1 }
        _ = observation
        observation = nil

        await delete(session)

        #expect(told == 0)
    }

    // MARK: - Delete failures

    @Test
    func testAFailedSnapshotWriteDeletesNothing() async throws {
        let folder = try makeFolder()
        let files = try contents(of: folder)
        let session = try makeRecording(in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let result = await delete(session)

        #expect(result == .moveFailed)
        #expect(try storedRecordings().count == 1)
        #expect(try contents(of: folder) == files)
        #expect(!undoManager.canUndo)
        #expect(announcements.isEmpty)
    }

    @Test
    func testAFailedMoveDeletesNothingAndRemovesTheSnapshot() async throws {
        let folder = try makeFolder()
        let files = try contents(of: folder)
        let session = try makeRecording(in: folder)
        // A read-only parent: the snapshot can be written into the session folder, but the folder
        // cannot be moved out of `recordings/`.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.recordingsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: workspace.recordingsURL.path) }

        let result = await delete(session)

        #expect(result == .moveFailed)
        #expect(try storedRecordings().count == 1)
        #expect(try contents(of: folder) == files)
        #expect(!undoManager.canUndo)
    }

    @Test
    func testAFolderOutsideTheWorkspaceIsRefusedAndNothingIsDeleted() async throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("mic.wav"))
        let session = try makeRecording(in: outside)

        let result = await delete(session)

        #expect(result == .moveFailed)
        #expect(try storedRecordings().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["mic.wav"])
    }

    @Test
    func testDeleteWithNoWorkspaceDeletesNothing() async throws {
        let session = try makeRecording(in: try makeFolder())
        workspaceService.currentWorkspaceResult = nil

        #expect(await delete(session) == .moveFailed)
        #expect(try storedRecordings().count == 1)
    }

    @Test
    func testAFailedSaveKeepsTheRecordAndMovesTheFolderBack() async throws {
        let folder = try makeFolder()
        let files = try contents(of: folder)
        let session = try makeRecording(in: folder)
        let id = session.id
        beforeSave = { throw CocoaError(.fileWriteUnknown) }

        let result = await delete(session)

        guard case .saveFailed = result else {
            Issue.record("Expected saveFailed, got \(result)")
            return
        }
        #expect(try storedRecordings().map(\.id) == [id])
        #expect(try context.fetch(FetchDescriptor<RecordingSession>()).map(\.id) == [id])
        #expect(try contents(of: folder) == files)
        #expect(!FileManager.default.fileExists(atPath: holding.heldFolder(for: id).path))
        #expect(!undoManager.canUndo)
        #expect(announcements.isEmpty)
    }

    @Test
    func testAFailedSaveWhoseMoveBackFailsLeavesTheFolderHeldWithItsSnapshot() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        let id = session.id
        beforeSave = { [workspace] in
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: workspace.recordingsURL.path)
            throw CocoaError(.fileWriteUnknown)
        }

        let result = await delete(session)

        guard case .saveFailed = result else {
            Issue.record("Expected saveFailed, got \(result)")
            return
        }
        #expect(try storedRecordings().map(\.id) == [id])
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
    }

    @Test
    func testTheSecurityScopeIsHeldUntilARollbackHasFinished() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        beforeSave = { throw CocoaError(.fileWriteUnknown) }
        var folderWasBackWhenScopeEnded = false
        var snapshotWasGoneWhenScopeEnded = false
        onStopAccess = {
            folderWasBackWhenScopeEnded = FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.wav").path)
            snapshotWasGoneWhenScopeEnded = !SessionSnapshot.exists(in: folder)
        }

        await delete(session)

        #expect(scopeEvents == ["start", "stop"])
        #expect(folderWasBackWhenScopeEnded)
        #expect(snapshotWasGoneWhenScopeEnded)
    }

    // MARK: - Undo and redo

    /// Every stored attribute of the two models, with how to tell an original from its restored
    /// copy. A stored property added to either model fails `testUndoRestoresEveryStoredProperty`
    /// until it is listed here, and then fails it again until the snapshot carries it.
    private static let recordingAttributes: [String: (RecordingSession, RecordingSession) -> Bool] = [
        "id": same(\.id),
        "createdAt": same(\.createdAt),
        "duration": same(\.duration),
        "micAudioURL": same(\.micAudioURL),
        "appAudioURL": same(\.appAudioURL),
        "screenVideoURL": same(\.screenVideoURL),
        "mixdownURL": same(\.mixdownURL),
        "title": same(\.title),
        "capturedAppName": same(\.capturedAppName),
        "statusRawValue": same(\.statusRawValue),
        "errorMessage": same(\.errorMessage),
        "screenCaptureWarning": same(\.screenCaptureWarning),
        "appAudioMissing": same(\.appAudioMissing),
        "captureInterruptionCount": same(\.captureInterruptionCount),
        "captureWriteFailureCount": same(\.captureWriteFailureCount),
        "partiallyCoveredSources": same(\.partiallyCoveredSources),
        "mixdownAttemptCountValue": same(\.mixdownAttemptCountValue),
        "screenMuxState": same(\.screenMuxState),
        "videoStartHostTimeNanos": same(\.videoStartHostTimeNanos),
        "audioAnchorHostTimeNanos": same(\.audioAnchorHostTimeNanos),
        "screenMuxAttemptCountValue": same(\.screenMuxAttemptCountValue),
        "audioSyncTimelineMixdownEnabled": same(\.audioSyncTimelineMixdownEnabled),
        "audioSyncUnifiedCaptureEnabled": same(\.audioSyncUnifiedCaptureEnabled),
        "audioSyncCaptureHealthRecoveryEnabled": same(\.audioSyncCaptureHealthRecoveryEnabled),
        "transcriptData": same(\.transcriptData),
        "retranscriptData": same(\.retranscriptData),
        "aiTransformationsData": same(\.aiTransformationsData),
        "searchableText": same(\.searchableText),
        "originalMixdownURL": same(\.originalMixdownURL),
        "originalScreenVideoURL": same(\.originalScreenVideoURL),
        "originalTranscriptData": same(\.originalTranscriptData),
        "originalRetranscriptData": same(\.originalRetranscriptData),
        "trimEnd": same(\.trimEnd),
    ]

    private static let segmentAttributes: [String: (RecordingTranscriptSegment, RecordingTranscriptSegment) -> Bool] = [
        "id": same(\.id),
        "createdAt": same(\.createdAt),
        "speakerId": same(\.speakerId),
        "text": same(\.text),
        "startTime": same(\.startTime),
        "endTime": same(\.endTime),
        "audioSourceRawValue": same(\.audioSourceRawValue),
        "isFinal": same(\.isFinal),
    ]

    private static func same<Model, Value: Equatable>(_ keyPath: KeyPath<Model, Value>) -> (Model, Model) -> Bool {
        { $0[keyPath: keyPath] == $1[keyPath: keyPath] }
    }

    private static func storedAttributeNames(of entityName: String) -> Set<String> {
        let schema = Schema([RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self])
        let entity = schema.entities.first { $0.name == entityName }
        return Set(entity?.attributes.map(\.name) ?? [])
    }

    @Test
    func testEveryStoredAttributeIsListedForTheRoundTrip() {
        #expect(Self.storedAttributeNames(of: "RecordingSession") == Set(Self.recordingAttributes.keys))
        #expect(Self.storedAttributeNames(of: "RecordingTranscriptSegment") == Set(Self.segmentAttributes.keys))
    }

    /// A recording with every stored attribute set to something other than its default.
    private func makeFullyPopulatedRecording(in folder: URL, tags: [RecordingTag]) throws -> RecordingSession {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSinceReferenceDate: 790_000_000.125),
            duration: 3_600.5,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            appAudioURL: folder.appendingPathComponent("app.wav").path,
            screenVideoURL: folder.appendingPathComponent("screen.mov").path,
            mixdownURL: folder.appendingPathComponent("recording.m4a").path,
            title: "Planning",
            capturedAppName: "Zoom",
            status: .error("boom"),
            mixdownAttemptCount: 2,
            transcriptData: Data("transcript".utf8),
            retranscriptData: Data("retranscript".utf8),
            aiTransformationsData: Data("transformations".utf8)
        )
        session.screenCaptureWarning = "warning"
        session.appAudioMissing = true
        session.captureInterruptionCount = 3
        session.captureWriteFailureCount = 4
        session.partiallyCoveredSources = ["mic", "app"]
        session.screenMuxState = ScreenMuxState.failed.rawValue
        session.videoStartHostTimeNanos = 123_456_789_012
        session.audioAnchorHostTimeNanos = 987_654_321_098
        session.screenMuxAttemptCountValue = 5
        session.audioSyncTimelineMixdownEnabled = true
        session.audioSyncUnifiedCaptureEnabled = false
        session.audioSyncCaptureHealthRecoveryEnabled = true
        session.searchableText = "searchable"
        session.originalMixdownURL = folder.appendingPathComponent("recording-original.m4a").path
        session.originalScreenVideoURL = folder.appendingPathComponent("screen-original.mov").path
        session.originalTranscriptData = Data("original transcript".utf8)
        session.originalRetranscriptData = Data("original retranscript".utf8)
        session.trimEnd = 1_800.25
        context.insert(session)
        session.tags = tags
        session.transcriptSegments = [
            RecordingTranscriptSegment(
                createdAt: Date(timeIntervalSinceReferenceDate: 790_000_001.5),
                speakerId: "S1", text: "Hello", startTime: 0.25, endTime: 1.75, audioSource: .app, isFinal: false
            ),
            RecordingTranscriptSegment(
                createdAt: Date(timeIntervalSinceReferenceDate: 790_000_002.5),
                speakerId: "S2", text: "Hi", startTime: 2, endTime: 3.5, audioSource: .mic
            ),
        ]
        try context.save()
        return session
    }

    /// Copies of what a session's stored attributes held, so they can be compared once the
    /// original object is gone.
    private func detachedCopy(of session: RecordingSession) -> (RecordingSession, [UUID: RecordingTranscriptSegment]) {
        let copy = RecordingSession(duration: 0, micAudioURL: "", title: "")
        for (name, _) in Self.recordingAttributes {
            Self.copyRecordingAttribute(name, from: session, to: copy)
        }
        let segments = Dictionary(uniqueKeysWithValues: session.transcriptSegments.map { segment in
            (segment.id, RecordingTranscriptSegment(
                id: segment.id, createdAt: segment.createdAt, speakerId: segment.speakerId, text: segment.text,
                startTime: segment.startTime, endTime: segment.endTime, audioSource: segment.audioSource,
                isFinal: segment.isFinal
            ))
        })
        return (copy, segments)
    }

    private static func copyRecordingAttribute(_ name: String, from source: RecordingSession, to copy: RecordingSession) {
        switch name {
        case "id": copy.id = source.id
        case "createdAt": copy.createdAt = source.createdAt
        case "duration": copy.duration = source.duration
        case "micAudioURL": copy.micAudioURL = source.micAudioURL
        case "appAudioURL": copy.appAudioURL = source.appAudioURL
        case "screenVideoURL": copy.screenVideoURL = source.screenVideoURL
        case "mixdownURL": copy.mixdownURL = source.mixdownURL
        case "title": copy.title = source.title
        case "capturedAppName": copy.capturedAppName = source.capturedAppName
        case "statusRawValue": copy.statusRawValue = source.statusRawValue
        case "errorMessage": copy.errorMessage = source.errorMessage
        case "screenCaptureWarning": copy.screenCaptureWarning = source.screenCaptureWarning
        case "appAudioMissing": copy.appAudioMissing = source.appAudioMissing
        case "captureInterruptionCount": copy.captureInterruptionCount = source.captureInterruptionCount
        case "captureWriteFailureCount": copy.captureWriteFailureCount = source.captureWriteFailureCount
        case "partiallyCoveredSources": copy.partiallyCoveredSources = source.partiallyCoveredSources
        case "mixdownAttemptCountValue": copy.mixdownAttemptCountValue = source.mixdownAttemptCountValue
        case "screenMuxState": copy.screenMuxState = source.screenMuxState
        case "videoStartHostTimeNanos": copy.videoStartHostTimeNanos = source.videoStartHostTimeNanos
        case "audioAnchorHostTimeNanos": copy.audioAnchorHostTimeNanos = source.audioAnchorHostTimeNanos
        case "screenMuxAttemptCountValue": copy.screenMuxAttemptCountValue = source.screenMuxAttemptCountValue
        case "audioSyncTimelineMixdownEnabled": copy.audioSyncTimelineMixdownEnabled = source.audioSyncTimelineMixdownEnabled
        case "audioSyncUnifiedCaptureEnabled": copy.audioSyncUnifiedCaptureEnabled = source.audioSyncUnifiedCaptureEnabled
        case "audioSyncCaptureHealthRecoveryEnabled": copy.audioSyncCaptureHealthRecoveryEnabled = source.audioSyncCaptureHealthRecoveryEnabled
        case "transcriptData": copy.transcriptData = source.transcriptData
        case "retranscriptData": copy.retranscriptData = source.retranscriptData
        case "aiTransformationsData": copy.aiTransformationsData = source.aiTransformationsData
        case "searchableText": copy.searchableText = source.searchableText
        case "originalMixdownURL": copy.originalMixdownURL = source.originalMixdownURL
        case "originalScreenVideoURL": copy.originalScreenVideoURL = source.originalScreenVideoURL
        case "originalTranscriptData": copy.originalTranscriptData = source.originalTranscriptData
        case "originalRetranscriptData": copy.originalRetranscriptData = source.originalRetranscriptData
        case "trimEnd": copy.trimEnd = source.trimEnd
        default: Issue.record("No copy for stored attribute \(name)")
        }
    }

    @Test
    func testUndoRestoresEveryStoredPropertyTagsSegmentsAndFiles() async throws {
        let work = try makeTag("Work")
        let client = try makeTag("Client")
        let folder = try makeFolder()
        let files = try contents(of: folder)
        let session = try makeFullyPopulatedRecording(in: folder, tags: [work, client])
        let (expected, expectedSegments) = detachedCopy(of: session)
        let id = session.id

        await delete(session)
        await undo()

        let fresh = ModelContext(container)
        let restored = try #require(try fresh.fetch(FetchDescriptor<RecordingSession>()).first { $0.id == id })
        for (name, isSame) in Self.recordingAttributes {
            #expect(isSame(expected, restored), "\(name) was not restored")
        }
        #expect(Set(restored.tags.map(\.id)) == [work.id, client.id])
        let segments = try fresh.fetch(FetchDescriptor<RecordingTranscriptSegment>())
        #expect(segments.count == expectedSegments.count)
        for segment in segments {
            #expect(segment.session?.id == id)
            let original = try #require(expectedSegments[segment.id])
            for (name, isSame) in Self.segmentAttributes {
                #expect(isSame(original, segment), "segment \(name) was not restored")
            }
        }
        #expect(Set(restored.transcriptSegments.map(\.id)) == Set(expectedSegments.keys))
        #expect(try contents(of: folder) == files)
        #expect(!FileManager.default.fileExists(atPath: holding.heldFolder(for: id).path))
        #expect(announcements == ["Session deleted", "Session restored"])
    }

    @Test
    func testUndoRegistersRedoAndRedoDeletesAgain() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        let id = session.id
        await delete(session)

        await undo()

        #expect(undoManager.canRedo)
        #expect(undoManager.redoActionName == UndoActionName.deleteSession)
        #expect(undoManager.redoMenuItemTitle == "Redo Delete Session")

        await redo()

        #expect(try storedRecordings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == UndoActionName.deleteSession)
        #expect(announcements == ["Session deleted", "Session restored", "Session deleted"])

        await undo()

        #expect(try storedRecordings().map(\.id) == [id])
    }

    @Test
    func testRedoResetsTheDeletionTime() async throws {
        var clock = deletedAt
        let coordinator = SessionDeletionCoordinator(
            workspaceService: workspaceService,
            now: { clock },
            announce: { _ in }
        )
        let session = try makeRecording(in: try makeFolder())
        let id = session.id
        await coordinator.delete(session, context: context, undoManager: undoManager)
        undoManager.undo()
        await coordinator.waitUntilIdle()
        clock = deletedAt.addingTimeInterval(3_600)

        undoManager.redo()
        await coordinator.waitUntilIdle()

        #expect(try SessionSnapshot.read(from: holding.heldFolder(for: id)).deletedAt == clock)
    }

    @Test
    func testTheEditMenuIsRightAsSoonAsTheUndoHandlerReturns() async throws {
        let session = try makeRecording(in: try makeFolder())
        await delete(session)

        undoManager.undo()

        #expect(!undoManager.canUndo)
        #expect(undoManager.canRedo)
        #expect(undoManager.redoActionName == UndoActionName.deleteSession)

        await coordinator.waitUntilIdle()
        undoManager.redo()

        #expect(undoManager.canUndo)
        #expect(!undoManager.canRedo)
        #expect(undoManager.undoActionName == UndoActionName.deleteSession)
        await coordinator.waitUntilIdle()
    }

    @Test
    func testRedoTellsRemovalObservers() async throws {
        let session = try makeRecording(in: try makeFolder())
        let id = session.id
        var told: [UUID] = []
        let observation = coordinator.observeRemovals { told.append($0) }
        await delete(session)
        await undo()

        await redo()

        #expect(told == [id, id])
        _ = observation
    }

    @Test
    func testATagDeletedDuringTheHoldIsSkippedOnRestore() async throws {
        let work = try makeTag("Work")
        let client = try makeTag("Client")
        let session = try makeRecording(in: try makeFolder())
        session.tags = [work, client]
        try context.save()
        let id = session.id
        await delete(session)
        try TagService().delete(client, in: context)

        await undo()

        let restored = try #require(try storedRecordings().first { $0.id == id })
        #expect(restored.tags.map(\.id) == [work.id])
    }

    @Test
    func testARecordingWhoseTagsWereAllDeletedComesBackWithTheDefaultTag() async throws {
        let defaultTag = try TagService().seedDefaultTagIfNeeded(in: context)
        let work = try makeTag("Work")
        let session = try makeRecording(in: try makeFolder())
        session.tags = [work]
        try context.save()
        let id = session.id
        await delete(session)
        try TagService().delete(work, in: context)

        await undo()

        let restored = try #require(try storedRecordings().first { $0.id == id })
        #expect(restored.tags.map(\.id) == [defaultTag.id])
    }

    @Test
    func testSeveralDeletesUndoNewestFirst() async throws {
        let first = try makeRecording(in: try makeFolder(named: "Recording A"), title: "A")
        let second = try makeRecording(in: try makeFolder(named: "Recording B"), title: "B")
        await delete(first)
        await delete(second)

        await undo()
        #expect(try storedRecordings().map(\.title) == ["B"])

        await undo()
        #expect(Set(try storedRecordings().map(\.title)) == ["A", "B"])
    }

    @Test
    func testATagChangeAfterADeleteUndoesBeforeTheDelete() async throws {
        let work = try makeTag("Work")
        let deleted = try makeRecording(in: try makeFolder(named: "Recording A"), title: "A")
        let other = try makeRecording(in: try makeFolder(named: "Recording B"), title: "B")
        await delete(deleted)
        undoManager.asOneEvent {
            _ = try? TagService().assign(work, to: other, in: context, undoManager: undoManager)
        }

        await undo()

        #expect(!other.tags.contains { $0.id == work.id })
        #expect(try storedRecordings().map(\.title) == ["B"])

        await undo()

        #expect(Set(try storedRecordings().map(\.title)) == ["A", "B"])
    }

    @Test
    func testAnEditFromBeforeTheDeleteDoesNothingOnceTheSessionIsRestored() async throws {
        let work = try makeTag("Work")
        let session = try makeRecording(in: try makeFolder())
        let id = session.id
        undoManager.asOneEvent {
            _ = try? TagService().assign(work, to: session, in: context, undoManager: undoManager)
        }
        await delete(session)
        await undo()

        await undo()

        let restored = try #require(try storedRecordings().first { $0.id == id })
        #expect(restored.tags.map(\.id) == [work.id])
    }

    // MARK: - Undo and redo failures

    @Test
    func testAFailedRestoreSaveRollsBackAndMovesTheFolderBackIntoHolding() async throws {
        let work = try makeTag("Work")
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        session.tags = [work]
        session.transcriptSegments = [
            RecordingTranscriptSegment(speakerId: "S1", text: "Hello", startTime: 0, endTime: 1, audioSource: .mic)
        ]
        try context.save()
        let id = session.id
        await delete(session)
        beforeSave = { throw CocoaError(.fileWriteUnknown) }

        await undo()

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<RecordingSession>()).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<RecordingTranscriptSegment>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<RecordingSession>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<RecordingTranscriptSegment>()).isEmpty)
        #expect(work.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(!undoManager.canRedo)
        #expect(announcements == ["Session deleted"])
    }

    @Test
    func testAFailedRestoreSaveWhoseMoveBackFailsLeavesTheFolderAtItsPathWithItsSnapshot() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        await delete(session)
        beforeSave = { [holding] in
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: holding.url.path)
            throw CocoaError(.fileWriteUnknown)
        }

        await undo()

        #expect(try storedRecordings().isEmpty)
        #expect(SessionSnapshot.exists(in: folder))
    }

    @Test
    func testRestoreIsRefusedWhenTheOriginalPathIsOccupied() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        let id = session.id
        await delete(session)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await undo()

        #expect(try storedRecordings().isEmpty)
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(!undoManager.canRedo)
    }

    @Test
    func testAFailedRestoreRemovesOnlyItsOwnEntriesAndKeepsTheRestInOrder() async throws {
        final class Target {}
        let first = Target()
        let second = Target()
        let session = try makeRecording(in: try makeFolder())
        for (target, name) in [(first, "First"), (second, "Second")] {
            undoManager.asOneEvent {
                undoManager.registerUndo(withTarget: target) { _ in }
                undoManager.setActionName(name)
            }
        }
        await delete(session)
        beforeSave = { throw CocoaError(.fileWriteUnknown) }

        await undo()

        #expect(!undoManager.canRedo)
        #expect(undoManager.undoActionName == "Second")
        undoManager.undo()
        #expect(undoManager.undoActionName == "First")
        _ = (first, second)
    }

    @Test
    func testAFailedRedoLeavesTheSessionRestoredAndNoStaleUndo() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        let id = session.id
        await delete(session)
        await undo()
        beforeSave = { throw CocoaError(.fileWriteUnknown) }

        await redo()

        #expect(try storedRecordings().map(\.id) == [id])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("mic.wav").path))
        #expect(!undoManager.canUndo)
        #expect(!undoManager.canRedo)
        #expect(announcements == ["Session deleted", "Session restored"])
    }

    @Test
    func testUndoOfASessionNoLongerHeldInTheActiveWorkspaceDoesNothingAndRemovesItself() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        let id = session.id
        await delete(session)
        let other = Workspace(rootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        workspaceService.currentWorkspaceResult = other

        await undo()

        #expect(try storedRecordings().isEmpty)
        #expect(SessionSnapshot.exists(in: holding.heldFolder(for: id)))
        #expect(!undoManager.canRedo)
        #expect(!undoManager.canUndo)
    }

    // MARK: - Serialization

    @Test
    func testTwoDeletesOfOneSessionFromTwoWindowsHoldItOnce() async throws {
        let session = try makeRecording(in: try makeFolder())
        let otherWindow = UndoManager.forTests()

        let first = Task { await self.coordinator.delete(session, context: self.context, undoManager: self.undoManager) }
        let second = Task { await self.coordinator.delete(session, context: self.context, undoManager: otherWindow) }
        let results = [await first.value, await second.value]

        #expect(results.filter { $0 == .deleted }.count == 2)
        #expect(undoManager.canUndo != otherWindow.canUndo)
        #expect(try FileManager.default.contentsOfDirectory(atPath: holding.url.path).count == 1)
        #expect(announcements == ["Session deleted"])
    }

    @Test
    func testAStaleRedoInOneWindowCannotDeleteASessionAnotherWindowHolds() async throws {
        let folder = try makeFolder()
        let session = try makeRecording(in: folder)
        let id = session.id
        let otherWindow = UndoManager.forTests()
        await delete(session)
        await undo()
        let restored = try #require(try context.fetch(FetchDescriptor<RecordingSession>()).first)
        await delete(restored, with: otherWindow)

        await redo()

        #expect(!undoManager.canRedo)
        #expect(!undoManager.canUndo)
        await undo(otherWindow)
        #expect(try storedRecordings().map(\.id) == [id])
    }
}
