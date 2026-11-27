import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftData
import Testing
@testable import Scriberman

final class RecordingServiceTests {
    private func fetchRecordingSession(id: UUID, from context: ModelContext) throws -> RecordingSession {
        var descriptor = FetchDescriptor<RecordingSession>()
        descriptor.fetchLimit = 1_000
        return try #require(context.fetch(descriptor).first(where: { $0.id == id }))
    }

    @Test(arguments: [false, true])
    func stopFinishesLiveAudioWithMissingSession(isRecording: Bool) async throws {
        let container = try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let service = RecordingService(workspaceService: MockWorkspaceService(), modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )
        let audio = AsyncStream<LiveAudioChunk>.makeStream()
        await service.setRecordingStateForTesting(isRecording: isRecording, liveAudioContinuation: audio.continuation)
        #expect(await service.stopRecording() == nil)
        var iterator = audio.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    // MARK: - Folder layout

    private static let utc = TimeZone(identifier: "UTC")!
    private static let march28At1430 = Date(timeIntervalSince1970: 1_774_708_200) // 2026-03-28 14:30 UTC

    @Test
    func testFolderNameIsDateAndTime() {
        #expect(RecordingFileLayout.folderName(createdAt: Self.march28At1430, timeZone: Self.utc) == "2026-03-28 14-30")
    }

    @Test
    func testFileURLsAreInsideTheGivenFolder() {
        let folderURL = URL(fileURLWithPath: "/tmp/workspace/recordings/2026-03-28 14-30", isDirectory: true)
        let urls = RecordingFileLayout.recordingFileURLs(in: folderURL)

        #expect(urls.mic == folderURL.appendingPathComponent("mic.wav"))
        #expect(urls.app == folderURL.appendingPathComponent("app.wav"))
        #expect(RecordingFileLayout.screenTmpVideoURL(in: folderURL) == folderURL.appendingPathComponent("screen-tmp.mov"))
        #expect(RecordingFileLayout.screenVideoURL(in: folderURL) == folderURL.appendingPathComponent("screen.mov"))
    }

    @Test
    func testCreateRecordingFolderUsesDateAndTimeName() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let folderURL = try RecordingFileLayout.createRecordingFolder(
            in: workspace,
            createdAt: Self.march28At1430,
            timeZone: Self.utc
        )

        #expect(folderURL == workspace.recordingsURL.appendingPathComponent("2026-03-28 14-30", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: folderURL.path))
    }

    @Test
    func testCreateRecordingFolderSkipsTakenNames() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        let first = workspace.recordingsURL.appendingPathComponent("2026-03-28 14-30", isDirectory: true)
        let second = workspace.recordingsURL.appendingPathComponent("2026-03-28 14-30 2", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let existingMic = first.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: existingMic.path, contents: Data("first".utf8))

        let folderURL = try RecordingFileLayout.createRecordingFolder(
            in: workspace,
            createdAt: Self.march28At1430,
            timeZone: Self.utc
        )

        #expect(folderURL.lastPathComponent == "2026-03-28 14-30 3")
        #expect(try Data(contentsOf: existingMic) == Data("first".utf8))
    }

    @Test
    func testCreateRecordingFolderInAnotherYearDoesNotCollide() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(
            at: workspace.recordingsURL.appendingPathComponent("2026-03-28 14-30", isDirectory: true),
            withIntermediateDirectories: true
        )

        let folderURL = try RecordingFileLayout.createRecordingFolder(
            in: workspace,
            createdAt: Date(timeIntervalSince1970: 1_806_244_200), // 2027-03-28 14:30 UTC
            timeZone: Self.utc
        )

        #expect(folderURL.lastPathComponent == "2027-03-28 14-30")
    }

    @Test
    func testCreateRecordingFolderFailsAfterLastSuffix() throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        for suffix in 1...RecordingFileLayout.maximumFolderSuffix {
            let name = suffix == 1 ? "2026-03-28 14-30" : "2026-03-28 14-30 \(suffix)"
            try FileManager.default.createDirectory(
                at: workspace.recordingsURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        #expect(throws: CocoaError.self) {
            try RecordingFileLayout.createRecordingFolder(
                in: workspace,
                createdAt: Self.march28At1430,
                timeZone: Self.utc
            )
        }
    }

    @Test

    func testMixdownFailureLeavesSessionMixdownURLNilAndStatusUnchanged() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
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
            micStartHostTime: HostNanoseconds(nanoseconds: 1),
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
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let result = await service.stopRecording()
        #expect(result == nil)
    }

    @Test

    func testCaptureHostTimesKeepsFirstObservedValues() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        await service.captureMicStartHostTimeIfNeeded(HostNanoseconds(nanoseconds: 1_000))
        await service.captureMicStartHostTimeIfNeeded(HostNanoseconds(nanoseconds: 2_000))
        await service.captureAppStartHostTimeIfNeeded(HostNanoseconds(nanoseconds: 3_000))
        await service.captureAppStartHostTimeIfNeeded(HostNanoseconds(nanoseconds: 4_000))

        let hostTimes = await service.capturedHostTimes()
        #expect(hostTimes.mic == HostNanoseconds(nanoseconds: 1_000))
        #expect(hostTimes.app == HostNanoseconds(nanoseconds: 3_000))
    }

    @Test
    func testStartRecordingWithNilDisplayDoesNotCreateScreenSession() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        _ = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: nil,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Session"
        )

        #expect(factoryProbe.callCount == 0)
        _ = await service.stopRecording()
    }

    @Test
    func testStopRecordingWithVideoLaunchesMixdownAndMuxTasks() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        screenSession.videoStartHostTime = HostNanoseconds(nanoseconds: 9_000)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        _ = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: 42,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Session"
        )

        let sessionID = await service.stopRecording()
        #expect(sessionID != nil)

        await mixdownCoordinator.waitForCall()
        await screenVideoMuxer.waitForCall()

        #expect(await mixdownCoordinator.callCount() == 1)
        #expect(await screenVideoMuxer.callCount() == 1)

        let mixdownStart = try #require(await mixdownCoordinator.firstCallStartedAt())
        let muxStart = try #require(await screenVideoMuxer.firstCallStartedAt())
        #expect(muxStart >= mixdownStart)

        // Stop saves what recovery needs to retry the mux (design D3).
        let stoppedID = try #require(sessionID)
        let session = try #require(try RecordingSession.fetch(id: stoppedID, in: ModelContext(container)))
        #expect(session.screenMuxState == ScreenMuxState.pending.rawValue)
        #expect(session.videoStartHostTimeNanos == 9_000)
        #expect(session.audioAnchorHostTimeNanos != nil)
    }

    @Test
    func testAudioAnchorIsTheEarlierStartTime() {
        let mic = HostNanoseconds(nanoseconds: 2_000_000_000)
        let app = HostNanoseconds(nanoseconds: 1_500_000_000)

        #expect(RecordingService.audioAnchorHostTime(mic: mic, app: app) == app)
        #expect(RecordingService.audioAnchorHostTime(mic: app, app: mic) == app)
        #expect(RecordingService.audioAnchorHostTime(mic: mic, app: nil) == mic)
    }

    @Test
    func testTwoStartsInTheSameMinuteUseDistinctFolders() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            now: { Self.march28At1430 },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let firstID = try await service.startRecording(in: workspace, title: "First")
        _ = await service.stopRecording()
        let context = ModelContext(container)
        let firstSession = try #require(try RecordingSession.fetch(id: firstID, in: context))
        let firstFolder = URL(fileURLWithPath: firstSession.micAudioURL).deletingLastPathComponent()
        _ = FileManager.default.createFile(
            atPath: firstFolder.appendingPathComponent("sentinel").path,
            contents: Data("first".utf8)
        )
        let firstContents = try folderSnapshot(at: firstFolder)

        let secondID = try await service.startRecording(in: workspace, title: "Second")
        _ = await service.stopRecording()
        let secondSession = try #require(try RecordingSession.fetch(id: secondID, in: ModelContext(container)))
        let secondFolder = URL(fileURLWithPath: secondSession.micAudioURL).deletingLastPathComponent()

        #expect(secondFolder.lastPathComponent == firstFolder.lastPathComponent + " 2")
        #expect(try folderSnapshot(at: firstFolder) == firstContents)
    }

    private func folderSnapshot(at folderURL: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folderURL.path) {
            snapshot[name] = try Data(contentsOf: folderURL.appendingPathComponent(name))
        }
        return snapshot
    }

    @Test
    func testConcurrentStopRequestsShareOneTeardown() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenSession = MockScreenCaptureSession()
        let stopBlocker = MockScreenCaptureStopBlocker()
        screenSession.blockNextStop(using: stopBlocker)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        _ = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: 42,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Session"
        )

        let firstStop = Task { await service.stopRecording() }
        await stopBlocker.waitUntilStopStarts()
        let secondStop = Task { await service.stopRecording() }
        while await service.stopRecordingCallCountForTesting() < 2 {
            await Task.yield()
        }
        await stopBlocker.release()

        let firstID = await firstStop.value
        let secondID = await secondStop.value
        #expect(firstID != nil)
        #expect(firstID == secondID)
        await mixdownCoordinator.waitForCall()
        #expect(await mixdownCoordinator.callCount() == 1)
        #expect(screenSession.stopCallCount == 1)
        #expect(await service.isRecording() == false)
    }

    @Test
    func testConcurrentStartRequestsStartOneRecording() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let permissionGate = MockScreenCaptureStopBlocker()

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {
                await permissionGate.markStopStarted()
                await permissionGate.waitUntilReleased()
            },
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let firstStart = Task { try await service.startRecording(in: workspace, title: "First") }
        await permissionGate.waitUntilStopStarts()

        var secondError: RecordingError?
        do {
            _ = try await service.startRecording(in: workspace, title: "Second")
        } catch {
            secondError = error
        }
        guard case .alreadyRecording = secondError else {
            Issue.record("Expected alreadyRecording, got \(String(describing: secondError))")
            return
        }

        await permissionGate.release()
        let firstID = try await firstStart.value
        #expect(await service.isRecording())

        let stoppedID = await service.stopRecording()
        #expect(stoppedID == firstID)
    }

    @Test
    func testFailedStartLeavesServiceReadyForNextStart() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let tagCalls = VPCallCounter()

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            defaultTagApplier: { session, context in
                tagCalls.increment()
                if tagCalls.callCount == 1 {
                    throw NSError(domain: "RecordingServiceTests", code: 11)
                }
                try TagService().applyDefaultTag(to: session, in: context)
            },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        var firstError: RecordingError?
        do {
            _ = try await service.startRecording(in: workspace, title: "Fails")
        } catch {
            firstError = error
        }
        guard case .failedToStart = firstError else {
            Issue.record("Expected failedToStart, got \(String(describing: firstError))")
            return
        }
        #expect(await service.isRecording() == false)

        let sessionID = try await service.startRecording(in: workspace, title: "Succeeds")
        #expect(await service.isRecording())
        #expect(await service.stopRecording() == sessionID)
    }

    @Test
    func testScreenCaptureErrorKeepsAudioRecordingAndSkipsMux() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        screenSession.videoStartHostTime = HostNanoseconds(nanoseconds: 5_000)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        _ = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: 42,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Session"
        )

        let tmpURL = try #require(screenSession.startedVideoURL)
        screenSession.emitError(NSError(domain: "RecordingServiceTests", code: 7))
        await Task.yield()
        await Task.yield()

        #expect(await service.isRecording())

        _ = await service.stopRecording()
        await mixdownCoordinator.waitForCall()
        #expect(await screenVideoMuxer.callCount() == 0)
        #expect(!FileManager.default.fileExists(atPath: tmpURL.path))
    }

    @Test
    func testConcurrentScreenCaptureErrorAndStopOnlyStopScreenSessionOnce() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        screenSession.videoStartHostTime = HostNanoseconds(nanoseconds: 5_000)
        let stopBlocker = MockScreenCaptureStopBlocker()
        screenSession.blockNextStop(using: stopBlocker)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        _ = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: 42,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Session"
        )

        let stopTask = Task { await service.stopRecording() }
        await stopBlocker.waitUntilStopStarts()

        screenSession.emitError(NSError(domain: "RecordingServiceTests", code: 8))
        await Task.yield()
        await Task.yield()

        await stopBlocker.release()

        let stoppedID = await stopTask.value
        #expect(stoppedID != nil)
        await mixdownCoordinator.waitForCall()
        #expect(screenSession.stopCallCount == 1)
        #expect(await screenVideoMuxer.callCount() == 0)
    }

    @Test
    func testStopRecordingWithDisplayIDButNoVideoFramesSetsScreenCaptureWarning() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        // videoStartHostTime remains nil — simulates no frames delivered by the stream.
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let sessionID = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: 42,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Session"
        )

        let stoppedID = await service.stopRecording()
        #expect(stoppedID != nil)
        await mixdownCoordinator.waitForCall()
        #expect(await screenVideoMuxer.callCount() == 0)

        let context = ModelContext(container)
        let session = try fetchRecordingSession(id: sessionID, from: context)
        #expect(session.screenCaptureWarning != nil)
    }

    @Test
    func testCleanupRecordingStateStopsScreenSession() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let screenSession = MockScreenCaptureSession()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let createdAt = Date(timeIntervalSince1970: 1_743_171_000)
        let recordingIdentifier = "cleanup-video"
        let folderURL = workspace.recordingsURL.appendingPathComponent(
            RecordingFileLayout.folderName(createdAt: createdAt),
            isDirectory: true
        )
        let screenTmpURL = RecordingFileLayout.screenTmpVideoURL(in: folderURL)
        try FileManager.default.createDirectory(
            at: screenTmpURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: screenTmpURL.path, contents: Data("video".utf8))

        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: recordingIdentifier,
            recordingWorkspaceRootURL: workspace.rootURL,
            recordingCreatedAt: createdAt,
            recordingFolderURL: folderURL,
            currentSessionID: UUID(),
            screenCaptureSession: screenSession
        )

        await service.cleanupRecordingStateForTesting()

        #expect(screenSession.stopCallCount == 1)
        #expect(!FileManager.default.fileExists(atPath: screenTmpURL.path))
    }

    @Test

    func testStartRecordingWithCustomTitlePersistsTitle() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let customTitle = "My Custom Title"
        let recordingCreatedAt = Date(timeIntervalSince1970: 1_743_171_000)
        let recordingIdentifier = "test-id"
        let folderURL = workspace.recordingsURL.appendingPathComponent(
            RecordingFileLayout.folderName(createdAt: recordingCreatedAt),
            isDirectory: true
        )
        let sessionURLs = RecordingFileLayout.recordingFileURLs(in: folderURL)
        try FileManager.default.createDirectory(
            at: sessionURLs.mic.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: sessionURLs.mic.path, contents: Data("mic".utf8))
        let seededSession = RecordingSession(
            createdAt: recordingCreatedAt,
            duration: 0,
            micAudioURL: sessionURLs.mic.path,
            title: customTitle,
            status: .recording
        )
        let seedContext = ModelContext(container)
        seedContext.insert(seededSession)
        try seedContext.save()

        // Fake the recording state
        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: recordingIdentifier,
            recordingWorkspaceRootURL: workspace.rootURL,
            recordingCreatedAt: recordingCreatedAt,
            recordingFolderURL: folderURL,
            pendingTitle: customTitle,
            currentSessionID: seededSession.id
        )

        let sessionID = await service.stopRecording()
        #expect(sessionID != nil)
        let ctx = ModelContext(container)
        let fetched = try fetchRecordingSession(id: try #require(sessionID), from: ctx)
        #expect(fetched.title == customTitle)
    }

    @Test
    func testStopRecordingFinalizesActiveSessionInLibraryOfFifteenHundred() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        let storeDirectory = workspace.rootURL.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(url: storeDirectory.appendingPathComponent("store.sqlite"))
        )
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let recordingCreatedAt = Date().addingTimeInterval(-5)
        let recordingIdentifier = "test-id-large-library"
        let folderURL = workspace.recordingsURL.appendingPathComponent(
            RecordingFileLayout.folderName(createdAt: recordingCreatedAt),
            isDirectory: true
        )
        let sessionURLs = RecordingFileLayout.recordingFileURLs(in: folderURL)
        try FileManager.default.createDirectory(
            at: sessionURLs.mic.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: sessionURLs.mic.path, contents: Data("mic".utf8))

        let seedContext = ModelContext(container)
        for index in 0..<1_499 {
            seedContext.insert(
                RecordingSession(duration: 0, micAudioURL: "/tmp/mic-\(index).wav", title: "Recording \(index)", status: .recorded)
            )
        }
        let activeSession = RecordingSession(
            createdAt: recordingCreatedAt,
            duration: 0,
            micAudioURL: sessionURLs.mic.path,
            title: "Active",
            status: .recording
        )
        seedContext.insert(activeSession)
        try seedContext.save()

        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: recordingIdentifier,
            recordingWorkspaceRootURL: workspace.rootURL,
            recordingCreatedAt: recordingCreatedAt,
            recordingFolderURL: folderURL,
            currentSessionID: activeSession.id
        )

        let sessionID = await service.stopRecording()
        #expect(sessionID == activeSession.id)

        await mixdownCoordinator.waitForCall()
        #expect(await mixdownCoordinator.callCount() == 1)

        let fetched = try #require(try RecordingSession.fetch(id: activeSession.id, in: ModelContext(container)))
        #expect(fetched.duration >= 5)
        #expect(fetched.status == .recorded)
    }

    @Test

    func testStopRecordingFallbacksToDefaultTitleWhenNoPendingTitle() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }

        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )

        let recordingCreatedAt = Date(timeIntervalSince1970: 1_743_171_000)
        let recordingIdentifier = "test-id-default"
        let folderURL = workspace.recordingsURL.appendingPathComponent(
            RecordingFileLayout.folderName(createdAt: recordingCreatedAt),
            isDirectory: true
        )
        let sessionURLs = RecordingFileLayout.recordingFileURLs(in: folderURL)
        try FileManager.default.createDirectory(
            at: sessionURLs.mic.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: sessionURLs.mic.path, contents: Data("mic".utf8))
        let seededSession = RecordingSession(
            createdAt: recordingCreatedAt,
            duration: 0,
            micAudioURL: sessionURLs.mic.path,
            title: "Recording Seed",
            status: .recording
        )
        let seedContext = ModelContext(container)
        seedContext.insert(seededSession)
        try seedContext.save()

        await service.setRecordingStateForTesting(
            isRecording: true,
            recordingIdentifier: recordingIdentifier,
            recordingWorkspaceRootURL: workspace.rootURL,
            recordingCreatedAt: recordingCreatedAt,
            recordingFolderURL: folderURL,
            pendingTitle: nil,
            currentSessionID: seededSession.id
        )

        let sessionID = await service.stopRecording()
        #expect(sessionID != nil)
        let ctx = ModelContext(container)
        let fetched = try fetchRecordingSession(id: try #require(sessionID), from: ctx)
        #expect(fetched.title.hasPrefix("Recording "))
    }

    private func makeStartFixture() async throws -> (
        service: RecordingService,
        workspace: Workspace,
        hardware: MockRecoveryAudioDeviceHardware
    ) {
        let workspace = makeWorkspace()
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            SpeakerProfile.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let hardware = MockRecoveryAudioDeviceHardware()
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: hardware,
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )
        return (service, workspace, hardware)
    }

    // MARK: - Default tag at creation

    @Test
    func testAStartedRecordingCarriesTheDefaultTag() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            SpeakerProfile.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)

        let sessionID = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "Tagged at birth"
        )

        let context = ModelContext(container)
        let session = try fetchRecordingSession(id: sessionID, from: context)
        // The bound holds from the moment the recording exists, not from first display.
        #expect(session.tags.count == 1)
        #expect(session.tags.first?.isDefault == true)

        _ = await service.stopRecording()
    }

    @Test
    func testTheDefaultTagSurvivesToStop() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            SpeakerProfile.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)

        let sessionID = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "Never tagged"
        )
        _ = await service.stopRecording()

        let context = ModelContext(container)
        let session = try fetchRecordingSession(id: sessionID, from: context)
        #expect(session.tags.count == 1)
        #expect(session.tags.first?.isDefault == true)
    }

    @Test
    func testARecordingTaggedDuringCaptureKeepsTheUserTags() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            SpeakerProfile.self, RecordingTag.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)
        let sessionID = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "Tagged mid-capture"
        )

        try await MainActor.run {
            let context = ModelContext(container)
            let tagService = TagService()
            let session = try #require(try RecordingSession.fetch(id: sessionID, in: context))
            let work = try tagService.createTag(name: "Work", in: context)
            _ = try tagService.assign(work, to: session, in: context)
        }

        _ = await service.stopRecording()

        let afterStop = ModelContext(container)
        let stopped = try fetchRecordingSession(id: sessionID, from: afterStop)
        #expect(stopped.tags.map(\.name) == ["Work"])
        #expect(!stopped.tags.contains { $0.isDefault })
    }

    // MARK: - Interrupted-capture marker

    private func makeScreenPauseService(
        workspace: Workspace,
        screenSession: MockScreenCaptureSession
    ) async throws -> RecordingService {
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)
        return RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )
    }

    @Test
    func testScreenCaptureFollowsTheRecordingsPauseClock() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        let screenSession = MockScreenCaptureSession()
        let service = try await makeScreenPauseService(workspace: workspace, screenSession: screenSession)

        _ = try await service.startRecording(in: workspace, captureDisplayID: 42, title: "Session")
        let clock = try #require(screenSession.startedPauseClock)
        #expect(clock.isPaused == false)

        #expect(await service.pauseRecording())
        #expect(clock.isPaused)
        #expect(screenSession.pauseCount == 1)
        #expect(await service.resumeRecording())
        #expect(clock.isPaused == false)
        #expect(screenSession.resumeCount == 1)
        _ = await service.stopRecording()
    }

    @Test
    func testAPauseDuringScreenCaptureStartReachesTheScreenSession() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        let screenSession = MockScreenCaptureSession()
        let service = try await makeScreenPauseService(workspace: workspace, screenSession: screenSession)
        screenSession.onStart = { _ = await service.pauseRecording() }

        _ = try await service.startRecording(in: workspace, captureDisplayID: 42, title: "Session")

        #expect(await service.isPaused())
        #expect(screenSession.pauseCount == 1)
        _ = await service.stopRecording()
    }

    private func makeServiceForStop(
        workspace: Workspace,
        container: ModelContainer
    ) async -> RecordingService {
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        return RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )
    }

    @Test
    func testStoppingAnInterruptedRecordingPersistsTheInterruptionCount() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)

        let sessionID = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: nil,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Interrupted"
        )
        await service.setCaptureRestartCountForTesting(2)
        _ = await service.stopRecording()

        let context = ModelContext(container)
        let session = try fetchRecordingSession(id: sessionID, from: context)
        #expect(session.captureInterruptionCount == 2)
        #expect(session.wasCaptureInterrupted)
    }

    @Test
    func testStoppingAfterWriteFailuresPersistsTheMarker() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)

        let sessionID = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "Failed writes"
        )
        await service.setWriteFailureOverrideForTesting(3)
        _ = await service.stopRecording()

        let context = ModelContext(container)
        let session = try fetchRecordingSession(id: sessionID, from: context)
        #expect(session.captureWriteFailureCount == 3)
        #expect(session.hadCaptureWriteFailures)
        // A caveat, not a failure: the audio it captured is intact.
        #expect(session.status == .recorded)
    }

    @Test
    func testStoppingWithoutWriteFailuresLeavesNoMarker() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)

        let sessionID = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "Clean writes"
        )
        _ = await service.stopRecording()

        let context = ModelContext(container)
        let session = try fetchRecordingSession(id: sessionID, from: context)
        #expect(session.captureWriteFailureCount == nil)
        #expect(!session.hadCaptureWriteFailures)
    }

    /// Write failures must never reach the restart trigger set: a restart cannot repair a full
    /// disk, and would destroy more audio than the failures did.
    @Test
    func testWriteFailuresAreNotPartOfTheCaptureHealthSnapshot() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)
        _ = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "Health"
        )

        let snapshot = await service.captureHealthSnapshot()
        var monitor = CaptureHealthMonitor()
        let now = Date()
        _ = monitor.update(now: now, snapshot: snapshot, isRecording: true)
        // Frames do not advance, but no stream failure is reported, so nothing here can be driven
        // by write failures — the snapshot carries no such field.
        #expect(snapshot.streamFailureCount == 0)

        _ = await service.stopRecording()
    }

    @Test
    func testStoppingACleanRecordingLeavesNoInterruptionMarker() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)

        let sessionID = try await service.startRecording(
            in: workspace,
            micDeviceID: nil,
            captureDisplayID: nil,
            capturedAppName: nil,
            appProcessID: nil,
            title: "Clean"
        )
        _ = await service.stopRecording()

        let context = ModelContext(container)
        let session = try fetchRecordingSession(id: sessionID, from: context)
        // nil rather than 0, matching how appAudioMissing stores "nothing to report".
        #expect(session.captureInterruptionCount == nil)
        #expect(!session.wasCaptureInterrupted)
    }

    @Test
    func testTheInterruptionCountIsResetByTheNextRecording() async throws {
        let workspace = makeWorkspace()
        defer { removeWorkspace(at: workspace.rootURL) }
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = await makeServiceForStop(workspace: workspace, container: container)

        _ = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "First"
        )
        await service.setCaptureRestartCountForTesting(3)
        _ = await service.stopRecording()

        let secondID = try await service.startRecording(
            in: workspace, micDeviceID: nil, captureDisplayID: nil,
            capturedAppName: nil, appProcessID: nil, title: "Second"
        )
        _ = await service.stopRecording()

        let context = ModelContext(container)
        let second = try fetchRecordingSession(id: secondID, from: context)
        // A clean recording must not inherit the previous one's interruptions.
        #expect(second.captureInterruptionCount == nil)
    }

    @Test
    func testNewMarkersRoundTripThroughAnOnDiskStore() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.sqlite")

        let markedID = UUID()
        let cleanID = UUID()
        do {
            let container = try ModelContainer(
                for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            let marked = RecordingSession(
                id: markedID, duration: 600, micAudioURL: "/tmp/a.wav", title: "Marked"
            )
            marked.captureWriteFailureCount = 4
            marked.partiallyCoveredSources = ["app"]
            let clean = RecordingSession(
                id: cleanID, duration: 600, micAudioURL: "/tmp/b.wav", title: "Clean"
            )
            context.insert(marked)
            context.insert(clean)
            try context.save()
        }

        let reopened = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let context = ModelContext(reopened)
        let sessions = try context.fetch(FetchDescriptor<RecordingSession>())
        let marked = try #require(sessions.first { $0.id == markedID })
        let clean = try #require(sessions.first { $0.id == cleanID })
        #expect(marked.captureWriteFailureCount == 4)
        #expect(marked.partiallyCoveredSources == ["app"])
        #expect(marked.hasPartiallyCoveredSource)
        // Rows written without the new attributes read back as nil, which is the half of
        // lightweight migration a unit test can cover.
        #expect(clean.captureWriteFailureCount == nil)
        #expect(clean.partiallyCoveredSources == nil)
        #expect(!clean.hasPartiallyCoveredSource)
    }

    /// Adding an optional attribute is SwiftData's lightweight-migration case. This exercises the
    /// half that can be checked in a unit test: an on-disk store round-trips, and rows written
    /// without the marker read back as nil rather than failing to load.
    ///
    /// Opening a store file created by a build that predates the attribute is verified by running
    /// the app against an existing workspace (chapter 10's real-hardware validation).
    @Test
    func testMarkerRoundTripsThroughAnOnDiskStore() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("store.sqlite")

        let markedID = UUID()
        let unmarkedID = UUID()
        do {
            let container = try ModelContainer(
                for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            let context = ModelContext(container)
            let marked = RecordingSession(
                id: markedID, duration: 10, micAudioURL: "/tmp/a.wav", title: "Marked"
            )
            marked.captureInterruptionCount = 4
            let unmarked = RecordingSession(
                id: unmarkedID, duration: 10, micAudioURL: "/tmp/b.wav", title: "Unmarked"
            )
            context.insert(marked)
            context.insert(unmarked)
            try context.save()
        }

        let reopened = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let context = ModelContext(reopened)
        let sessions = try context.fetch(FetchDescriptor<RecordingSession>())
        #expect(sessions.count == 2)
        #expect(sessions.first { $0.id == markedID }?.captureInterruptionCount == 4)
        #expect(sessions.first { $0.id == unmarkedID }?.captureInterruptionCount == nil)
        #expect(sessions.first { $0.id == unmarkedID }?.wasCaptureInterrupted == false)
    }

    // MARK: - Per-recording audio-sync flags

    private func makeFlagFixture(captureDisplayID: CGDirectDisplayID? = nil, writesAudio: Bool = true) async throws -> (
        service: RecordingService,
        container: ModelContainer,
        workspace: Workspace,
        captureStarts: CaptureStartProbe,
        mixdownCoordinator: MockRecordingMixdownCoordinator,
        screenVideoMuxer: MockScreenVideoMuxer
    ) {
        let workspace = makeWorkspace()
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let workspaceService = MockWorkspaceService()
        workspaceService.requireWritableResult = .success(workspace)
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        screenSession.videoStartHostTime = HostNanoseconds(nanoseconds: 9_000)
        let captureStarts = CaptureStartProbe(writesAudio: writesAudio)
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            hardware: MockRecoveryAudioDeviceHardware(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { screenSession },
            captureSessionStarter: { try await captureStarts.start($0) }
        )
        return (service, container, workspace, captureStarts, mixdownCoordinator, screenVideoMuxer)
    }

    private func flags(timeline: Bool = true, recovery: Bool = true) -> AudioSyncFlags {
        AudioSyncFlags(
            isTimelineMixdownEnabled: timeline,

            isCaptureHealthRecoveryEnabled: recovery
        )
    }

    @Test
    func testCaptureRestartUsesUnifiedCapture() async throws {
        let fixture = try await makeFlagFixture(writesAudio: false)
        defer { removeWorkspace(at: fixture.workspace.rootURL) }

        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            appProcessID: 4321,
            title: "Session",
            audioSyncFlags: flags()
        )
        let restarted = await fixture.service.restartAudioCapture()
        _ = await fixture.service.stopRecording()

        let expected: CaptureStartProbe.Kind = .unified
        #expect(restarted)
        #expect(fixture.captureStarts.kinds == [expected, expected])
    }

    @Test(arguments: [true, false])
    func testFinalizationUsesTheTimelineModeTheRecordingStartedWith(timeline: Bool) async throws {
        let fixture = try await makeFlagFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }

        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            captureDisplayID: 42,
            title: "Session",
            audioSyncFlags: flags(timeline: timeline)
        )
        _ = await fixture.service.stopRecording()
        await fixture.mixdownCoordinator.waitForCall()
        await fixture.screenVideoMuxer.waitForCall()

        #expect(await fixture.mixdownCoordinator.timelineModes() == [timeline])
        let request = try #require(await fixture.screenVideoMuxer.requests().first)
        #expect((request.timelineAudioURL != nil) == timeline)
        #expect((request.audioAnchorHostTime != nil) == timeline)
    }

    @Test
    func testRecordingStoresItsFlagSnapshotWhenItStarts() async throws {
        let fixture = try await makeFlagFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        let started = flags(timeline: false, recovery: false)

        let sessionID = try await fixture.service.startRecording(
            in: fixture.workspace,
            title: "Session",
            audioSyncFlags: started
        )
        // Read while still recording: a crash from here on must find the snapshot.
        let session = try #require(try RecordingSession.fetch(id: sessionID, in: ModelContext(fixture.container)))
        #expect(session.audioSyncFlags == started)
        _ = await fixture.service.stopRecording()
    }

    private func makeWorkspace() -> Workspace {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return Workspace(rootURL: rootURL)
    }

    private func removeWorkspace(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Capture frame counts (start safety net signal)

    @Test
    func testFrameCountsReportUnifiedSessionCountersWhenUnifiedCaptureIsActive() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        let counts = await fixture.service.captureFrameCounts()

        // Nothing has been written, which is exactly the state the safety net must be able to see.
        #expect(counts.mic == 0)
        #expect(counts.micWriteFailures == 0)
    }

    @Test
    func testFrameCountsReportNilAppWhenAppAudioIsNotBeingCaptured() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        let counts = await fixture.service.captureFrameCounts()

        #expect(counts.app == nil)
    }

    // MARK: - Mic resilience under unified ScreenCaptureKit capture

    private func makeUnifiedSession(micDeviceUID: String?) -> UnifiedCaptureSession {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return UnifiedCaptureSession(
            micFileURL: root.appendingPathComponent("mic.wav"),
            appFileURL: root.appendingPathComponent("app.wav"),
            processID: 4321,
            micDeviceUID: micDeviceUID
        )
    }

    @Test
    func testRetargetMicUpdatesLiveStream() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 1, uid: "device-a"), (id: 2, uid: "device-b")]

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        let stream = StubUnifiedStream()
        unified.attachStreamForTesting(stream)
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "device-a",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        await fixture.service.retargetMic(desiredDeviceUID: "device-b")

        #expect(stream.updateCallCount == 1)
        #expect(unified.currentMicDeviceUID == "device-b")
        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testFailedUnifiedRetargetKeepsSessionActiveWithoutError() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 1, uid: "device-a"), (id: 2, uid: "device-b")]

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        let stream = StubUnifiedStream()
        stream.updateError = StubUnifiedStreamError()
        unified.attachStreamForTesting(stream)
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "device-a",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        await fixture.service.retargetMic(desiredDeviceUID: "device-b")

        #expect(unified.currentMicDeviceUID == "device-a")
        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testRetargetMicWhileNotRecordingIsNoOpUnderUnifiedCapture() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        let stream = StubUnifiedStream()
        unified.attachStreamForTesting(stream)
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        await fixture.service.retargetMic(desiredDeviceUID: "device-b")

        #expect(stream.updateCallCount == 0)
        #expect(unified.currentMicDeviceUID == "device-a")
    }

    @Test
    func testHardwareChangeRetargetsUnifiedCaptureWhenPreferredMicReappears() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 1, uid: "device-a"), (id: 2, uid: "device-b")]

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        let stream = StubUnifiedStream()
        unified.attachStreamForTesting(stream)
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "device-b",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        await fixture.service.simulateHardwareChangeForTesting()

        #expect(stream.updateCallCount == 1)
        #expect(unified.currentMicDeviceUID == "device-b")
    }

    @Test
    func testHardwareChangeDoesNotRetargetWhenAlreadyOnPreferredMic() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 1, uid: "device-a"), (id: 2, uid: "device-b")]

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        let stream = StubUnifiedStream()
        unified.attachStreamForTesting(stream)
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "device-a",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        await fixture.service.simulateHardwareChangeForTesting()

        #expect(stream.updateCallCount == 0)
    }

    @Test
    func testHardwareChangeDoesNotRetargetWhenPreferredMicIsAbsent() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        // The preferred device is not among the currently available devices; the recording started
        // on device-a, which is still usable.
        fixture.hardware.devices = [(id: 1, uid: "device-a")]

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        let stream = StubUnifiedStream()
        unified.attachStreamForTesting(stream)
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "device-b",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav"),
            fallbackMicDeviceUID: "device-a"
        )
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        await fixture.service.simulateHardwareChangeForTesting()

        #expect(stream.updateCallCount == 0)
        #expect(unified.currentMicDeviceUID == "device-a")
    }

    private func makeRecoveryFixture() async throws -> (
        service: RecordingService,
        workspace: Workspace,
        hardware: MockRecoveryAudioDeviceHardware
    ) {
        let workspace = makeWorkspace()
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let modelContainer = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let hardware = MockRecoveryAudioDeviceHardware()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: modelContainer,
            hardware: hardware,
            captureSessionStarter: { try await CaptureStartProbe().start($0) }
        )
        return (service, workspace, hardware)
    }
}

// Thread-safe call counter for injected operations.
private final class VPCallCounter: @unchecked Sendable {
    private(set) var callCount = 0
    func increment() { callCount += 1 }
}

private final class ScreenCaptureSessionFactoryProbe: @unchecked Sendable {
    private let session: MockScreenCaptureSession
    private(set) var callCount = 0

    init(session: MockScreenCaptureSession) {
        self.session = session
    }

    func makeSession() -> MockScreenCaptureSession {
        callCount += 1
        return session
    }
}

private final class MockScreenCaptureSession: ScreenCaptureSessionControlling, @unchecked Sendable {
    var onError: (@Sendable (Error) -> Void)?
    var videoStartHostTime: HostNanoseconds?
    var startError: Error?
    private(set) var startedVideoURL: URL?
    private(set) var startedPauseClock: RecordingPauseClock?
    private(set) var stopCallCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    var onStart: (@Sendable () async -> Void)?
    private var stopBlocker: MockScreenCaptureStopBlocker?

    func start(displayID _: CGDirectDisplayID, videoURL: URL, pauseClock: RecordingPauseClock) async throws {
        if let startError {
            throw startError
        }
        startedVideoURL = videoURL
        startedPauseClock = pauseClock
        await onStart?()
        try FileManager.default.createDirectory(
            at: videoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: videoURL.path, contents: Data("screen".utf8))
    }

    func stop() async {
        stopCallCount += 1
        if let stopBlocker {
            self.stopBlocker = nil
            await stopBlocker.markStopStarted()
            await stopBlocker.waitUntilReleased()
        }
    }

    func recordingDidPause() {
        pauseCount += 1
    }

    func recordingDidResume() {
        resumeCount += 1
    }

    func emitError(_ error: Error) {
        onError?(error)
    }

    func blockNextStop(using blocker: MockScreenCaptureStopBlocker) {
        stopBlocker = blocker
    }
}

private actor MockScreenCaptureStopBlocker {
    private var didStartStop = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func markStopStarted() {
        didStartStop = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStopStarts() async {
        if didStartStop {
            return
        }

        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        if isReleased {
            return
        }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor MockRecordingMixdownCoordinator: RecordingMixdownCoordinating {
    private struct Call: Sendable {
        let startedAt: Date
        let timelineMixdown: Bool
    }

    private var calls: [Call] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func runMixdown(
        sessionID _: UUID,
        micURL _: URL,
        appURL _: URL?,
        mixdownURL _: URL,
        micStartHostTime _: HostNanoseconds,
        appStartHostTime _: HostNanoseconds?,
        timelineMixdown: Bool
    ) async -> Bool {
        calls.append(Call(startedAt: Date(), timelineMixdown: timelineMixdown))
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
        return false
    }

    func waitForCall() async {
        if !calls.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func callCount() -> Int {
        calls.count
    }

    func firstCallStartedAt() -> Date? {
        calls.first?.startedAt
    }

    func timelineModes() -> [Bool] {
        calls.map(\.timelineMixdown)
    }
}

private actor MockScreenVideoMuxer: ScreenVideoMuxing {
    private struct Call: Sendable {
        let startedAt: Date
        let request: ScreenVideoMuxRequest
    }

    private var calls: [Call] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func runMux(request: ScreenVideoMuxRequest) async {
        calls.append(Call(startedAt: Date(), request: request))
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func waitForCall() async {
        if !calls.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func callCount() -> Int {
        calls.count
    }

    func firstCallStartedAt() -> Date? {
        calls.first?.startedAt
    }

    func requests() -> [ScreenVideoMuxRequest] {
        calls.map(\.request)
    }
}

private final class MockRecoveryAudioDeviceHardware: AudioDeviceHardwareProviding, @unchecked Sendable {
    var devices: [(id: AudioDeviceID, uid: String)] = [(1, "device-a")]
    var deadDeviceIDs: Set<AudioDeviceID> = []
    var privateAggregateIDs: Set<AudioDeviceID> = []
    var outputOnlyDeviceIDs: Set<AudioDeviceID> = []

    func allDeviceIDs() throws -> [AudioDeviceID] {
        devices.map(\.id)
    }

    func inputChannelCount(deviceID: AudioDeviceID) -> Int {
        outputOnlyDeviceIDs.contains(deviceID) ? 0 : 1
    }

    func deviceUID(deviceID: AudioDeviceID) -> String? {
        devices.first(where: { $0.id == deviceID })?.uid
    }

    func deviceName(deviceID _: AudioDeviceID) -> String? {
        "Mock Device"
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        devices.first?.id
    }

    func isAlive(deviceID: AudioDeviceID) -> Bool {
        !deadDeviceIDs.contains(deviceID)
    }

    func isPrivateAggregate(deviceID: AudioDeviceID) -> Bool {
        privateAggregateIDs.contains(deviceID)
    }
}

private struct StubUnifiedStreamError: Error {}

private final class StubUnifiedStream: UnifiedCaptureStreaming, @unchecked Sendable {
    var updateError: Error?
    private(set) var updateCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    func addStreamOutput(
        _: SCStreamOutput,
        type _: SCStreamOutputType,
        sampleHandlerQueue _: DispatchQueue?
    ) throws {}

    func startCapture() async throws {
        startCallCount += 1
    }

    func stopCapture() async throws {
        stopCallCount += 1
    }

    func updateConfiguration(_: SCStreamConfiguration) async throws {
        updateCallCount += 1
        if let updateError {
            throw updateError
        }
    }
}

/// Records which capture session each start used, and starts it on a stub stream so no test
/// reaches ScreenCaptureKit.
private final class CaptureStartProbe: @unchecked Sendable {
    enum Kind: Equatable {
        case unified
    }

    private let writesAudio: Bool

    init(writesAudio: Bool = true) { self.writesAudio = writesAudio }

    private let lock = NSLock()
    private var recorded: [Kind] = []

    var kinds: [Kind] {
        lock.withLock { recorded }
    }

    func start(_ start: RecordingService.CaptureSessionStart) async throws {
        switch start {
        case .unified(let session):
            lock.withLock { recorded.append(.unified) }
            try await session.start(stream: StubUnifiedStream())
            if writesAudio {
                let buffer = try CaptureAudioGateTests.makeSampleBuffer(
                    Array(repeating: CaptureAudioGateTests.before, count: 960), sampleRate: 48_000,
                    hostTime: HostNanoseconds(machTicks: mach_absolute_time())
                )
                session.micHandler.processSampleBufferForTesting(buffer)
                if session.hasAppSource { session.appHandler.processSampleBufferForTesting(buffer) }
            }
        }
    }
}
