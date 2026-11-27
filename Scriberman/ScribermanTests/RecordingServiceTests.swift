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
        let settings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(workspaceService: MockWorkspaceService(), modelContainer: container, appAudioSettings: settings)
        let audio = AsyncStream<LiveAudioChunk>.makeStream()
        await service.setRecordingStateForTesting(isRecording: isRecording, liveAudioContinuation: audio.continuation)
        #expect(await service.stopRecording() == nil)
        var iterator = audio.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test
    func engineMicPathPreservesCaptureTime() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        let audio = AsyncStream<LiveAudioChunk>.makeStream()
        await fixture.service.setRecordingStateForTesting(isRecording: true, liveAudioContinuation: audio.continuation)
        await fixture.service.setMicRecoveryStateForTesting(desiredMicDeviceUID: nil, micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav"))
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()
        let emit = try #require(fixture.micController.onBuffer)
        let time = HostNanoseconds(nanoseconds: 2_000_000_000)
        emit(.audio(samples: [1, 2], sampleRate: 48_000, hostTime: time, rawHostTime: time))
        _ = await fixture.service.stopRecording()
        var iterator = audio.stream.makeAsyncIterator()
        let chunk = try #require(await iterator.next())
        #expect(chunk.hostTime == time)
        #expect(chunk.source == .mic)
        #expect(chunk.samples == [1, 2])
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let micController = MockMicCaptureController()
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: micController,
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let micController = MockMicCaptureController()
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        screenSession.videoStartHostTime = HostNanoseconds(nanoseconds: 9_000)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: micController,
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() }
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
    func testEngineTapHostTimeConvertsToNanoseconds() {
        let ticks = AVAudioTime.hostTime(forSeconds: 2.5)

        #expect(AVAudioEngineMicCaptureController.hostTime(of: AVAudioTime(hostTime: ticks)) == HostNanoseconds(nanoseconds: 2_500_000_000))
        #expect(AVAudioEngineMicCaptureController.hostTime(of: AVAudioTime(hostTime: 0)) == nil)
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: MockMicCaptureController(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            now: { Self.march28At1430 }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenSession = MockScreenCaptureSession()
        let stopBlocker = MockScreenCaptureStopBlocker()
        screenSession.blockNextStop(using: stopBlocker)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: MockMicCaptureController(),
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let permissionGate = MockScreenCaptureStopBlocker()

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: MockMicCaptureController(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {
                await permissionGate.markStopStarted()
                await permissionGate.waitUntilReleased()
            },
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let tagCalls = VPCallCounter()

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: MockMicCaptureController(),
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
            }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let micController = MockMicCaptureController()
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        screenSession.videoStartHostTime = HostNanoseconds(nanoseconds: 5_000)
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: micController,
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let micController = MockMicCaptureController()
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
            appAudioSettings: appAudioSettings,
            micCaptureController: micController,
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let micController = MockMicCaptureController()
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        // videoStartHostTime remains nil — simulates no frames delivered by the stream.
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)

        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: micController,
            mixdownCoordinator: mixdownCoordinator,
            screenVideoMuxer: screenVideoMuxer,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let screenSession = MockScreenCaptureSession()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in }
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

        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            mixdownCoordinator: mixdownCoordinator
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings
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

    @Test @MainActor
    func testVoiceProcessingSetterCalledWhenEnabled() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suiteName = "RecordingServiceTests.vp.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName) ?? .standard
        ud.removePersistentDomain(forName: suiteName)
        defer { ud.removePersistentDomain(forName: suiteName) }

        let appAudioSettings = AppAudioSettings(userDefaults: ud)
        appAudioSettings.voiceProcessingEnabled = true

        let counter = VPCallCounter()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            voiceProcessingPropertySetter: { @Sendable [counter] _ in counter.increment() }
        )

        let inputNode = unsafeBitCast(NSObject(), to: AVAudioInputNode.self)
        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: true)
        #expect(counter.callCount == 1)

        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: false)
        #expect(counter.callCount == 1) // not called again when disabled
    }

    @Test @MainActor
    func testVoiceProcessingSetterNotCalledWhenDisabled() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let appAudioSettings = AppAudioSettings()
        // voiceProcessingEnabled defaults to false

        let counter = VPCallCounter()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            voiceProcessingPropertySetter: { @Sendable [counter] _ in counter.increment() }
        )

        let inputNode = unsafeBitCast(NSObject(), to: AVAudioInputNode.self)
        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: false)
        #expect(counter.callCount == 0)
    }

    @Test @MainActor
    func testVoiceProcessingSetterErrorDoesNotInterruptFlow() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let appAudioSettings = AppAudioSettings()
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            voiceProcessingPropertySetter: { @Sendable _ in
                throw NSError(domain: "test", code: -1, userInfo: nil) // simulate failure
            }
        )

        let inputNode = unsafeBitCast(NSObject(), to: AVAudioInputNode.self)
        // Should not throw or crash; failure is logged and recording continues
        service.applyVoiceProcessingIfNeeded(to: inputNode, enabled: true)
        // Reaching here means no crash/throw
    }

    @Test
    func testConfigChangeWhileRecordingRecoverySuccessKeepsRecordingAndNoPendingError() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testConfigChangeWhileRecordingRecoveryFailureKeepsRecordingAndSchedulesRetry() async throws {
        let fixture = try await makeRecoveryFixture()
        fixture.micController.startCaptureError = RecordingError.failedToStart("forced")
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.consumePendingError() == nil)
        let debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(debugState.hasRecoveryRetryTask)
    }

    @Test
    func testConfigChangeWhileRecorderFallbackIsNoOp() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL,
            recorderFallbackActive: true
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(await fixture.service.consumePendingError() == nil)
        #expect(fixture.micController.startCaptureCalls.isEmpty)
    }

    @Test
    func testReentrantConfigChangeDuringRecoveryIsIgnored() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL,
            isRecoveringMicCapture: true
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.isEmpty)
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testMicStartHostTimeNotOverwrittenOnRecovery() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: micURL
        )
        await fixture.service.captureMicStartHostTimeIfNeeded(HostNanoseconds(nanoseconds: 1_000))
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()
        await fixture.service.captureMicStartHostTimeIfNeeded(HostNanoseconds(nanoseconds: 2_000))

        #expect(await fixture.service.capturedHostTimes().mic == HostNanoseconds(nanoseconds: 1_000))
    }

    @Test
    func testRecoveryResolvesDesiredUIDToMatchingDeviceID() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a"),
            (id: 22, uid: "uid-b")
        ]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-b",
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 22)
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testRecoveryUIDNotFoundFallsBackToDefaultDevice() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a")
        ]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-missing",
            micFileURL: micURL
        )
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == nil)
        #expect(await fixture.service.consumePendingError() == nil)
    }

    @Test
    func testRetargetMicWhileNotRecordingIsNoOp() async throws {
        let fixture = try await makeRecoveryFixture()

        await fixture.service.setRecordingStateForTesting(isRecording: false)
        await fixture.service.retargetMic(desiredDeviceUID: "uid-b")

        #expect(fixture.micController.startCaptureCalls.isEmpty)
    }

    @Test
    func testRetargetMicWhileRecordingUpdatesDesiredUIDAndTriggersRecovery() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a"),
            (id: 22, uid: "uid-b")
        ]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-a",
            micFileURL: micURL
        )

        await fixture.service.retargetMic(desiredDeviceUID: "uid-b")

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 22)
        let debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(debugState.desiredMicDeviceUID == "uid-b")
    }

    @Test
    func testRetargetMicRecoveryFailureSchedulesRetryThatCanRecoverLater() async throws {
        let fixture = try await makeRecoveryFixture()
        let micURL = fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        fixture.hardware.devices = [
            (id: 11, uid: "uid-a"),
            (id: 22, uid: "uid-b")
        ]
        fixture.micController.startCaptureErrors = [RecordingError.failedToStart("forced once")]

        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-a",
            micFileURL: micURL
        )

        await fixture.service.retargetMic(desiredDeviceUID: "uid-b")
        var debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(debugState.hasRecoveryRetryTask)

        await fixture.service.performMicRecoveryRetryAttemptForTesting()

        debugState = await fixture.service.recoveryDebugStateForTesting()
        #expect(!debugState.hasRecoveryRetryTask)
        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 22)
    }

    // MARK: - Preferred mic carried separately from the start device

    @Test
    func aRecordingStartedOnTheDefaultSwitchesToThePreferredMicWhenItAppears() async throws {
        let fixture = try await makeStartFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin")]

        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            micDeviceID: 11,
            preferredMicDeviceUID: "airpods",
            title: "Session",
            audioSyncFlags: .shippedDefaults
        )
        #expect(fixture.micController.startCaptureCalls.map(\.deviceID) == [11])

        fixture.hardware.devices.append((id: 22, uid: "airpods"))
        await fixture.service.simulateHardwareChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 22)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aFailedExplicitRouteStartKeepsThePreferredMicAndRecordsOnTheDefault() async throws {
        let fixture = try await makeStartFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin"), (id: 22, uid: "airpods")]
        fixture.micController.startCaptureErrors = [RecordingError.failedToStart("explicit route")]

        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            micDeviceID: 22,
            preferredMicDeviceUID: "airpods",
            title: "Session",
            audioSyncFlags: .shippedDefaults
        )

        #expect(fixture.micController.startCaptureCalls.map(\.deviceID) == [nil])
        let state = await fixture.service.recoveryDebugStateForTesting()
        #expect(state.desiredMicDeviceUID == "airpods")
        #expect(state.currentCaptureDeviceID == nil)
        _ = await fixture.service.stopRecording()
    }

    /// The device that refused the route is still there, so retrying it on every hardware event
    /// would tear down working capture each time. It is tried again once it has left and returned.
    @Test
    func aMicThatRefusedTheRouteIsRetriedOnlyAfterItReturns() async throws {
        let fixture = try await makeStartFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin"), (id: 22, uid: "airpods")]
        fixture.micController.startCaptureErrors = [RecordingError.failedToStart("explicit route")]
        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            micDeviceID: 22,
            preferredMicDeviceUID: "airpods",
            title: "Session",
            audioSyncFlags: .shippedDefaults
        )

        await fixture.service.simulateHardwareChangeForTesting()
        #expect(fixture.micController.startCaptureCalls.map(\.deviceID) == [nil])

        fixture.hardware.devices = [(id: 11, uid: "builtin")]
        await fixture.service.simulateHardwareChangeForTesting()
        fixture.hardware.devices = [(id: 11, uid: "builtin"), (id: 22, uid: "airpods")]
        await fixture.service.simulateHardwareChangeForTesting()

        #expect(fixture.micController.startCaptureCalls.map(\.deviceID) == [nil, 22])
        _ = await fixture.service.stopRecording()
    }

    private func makeStartFixture() async throws -> (
        service: RecordingService,
        workspace: Workspace,
        hardware: MockRecoveryAudioDeviceHardware,
        micController: MockMicCaptureController
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
        let micController = MockMicCaptureController()
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            hardware: hardware,
            micCaptureController: micController,
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in }
        )
        return (service, workspace, hardware, micController)
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let factoryProbe = ScreenCaptureSessionFactoryProbe(session: screenSession)
        return RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: MockMicCaptureController(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            screenCaptureSessionFactory: { factoryProbe.makeSession() }
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        return RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: MockMicCaptureController(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in }
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

    private func makeFlagFixture(captureDisplayID: CGDirectDisplayID? = nil) async throws -> (
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
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let mixdownCoordinator = MockRecordingMixdownCoordinator()
        let screenVideoMuxer = MockScreenVideoMuxer()
        let screenSession = MockScreenCaptureSession()
        screenSession.videoStartHostTime = HostNanoseconds(nanoseconds: 9_000)
        let captureStarts = CaptureStartProbe()
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            micCaptureController: MockMicCaptureController(),
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

    private func flags(timeline: Bool = true, unified: Bool = true, recovery: Bool = true) -> AudioSyncFlags {
        AudioSyncFlags(
            isTimelineMixdownEnabled: timeline,
            isUnifiedCaptureEnabled: unified,
            isCaptureHealthRecoveryEnabled: recovery
        )
    }

    @Test(arguments: [true, false])
    func testCaptureRestartUsesTheCaptureModeTheRecordingStartedWith(unified: Bool) async throws {
        let fixture = try await makeFlagFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }

        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            appProcessID: 4321,
            title: "Session",
            audioSyncFlags: flags(unified: unified)
        )
        let restarted = await fixture.service.restartAudioCapture()
        _ = await fixture.service.stopRecording()

        let expected: CaptureStartProbe.Kind = unified ? .unified : .appAudio
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
        let started = flags(timeline: false, unified: true, recovery: false)

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

    @Test
    func testFrameCountsReportMicOnLegacyPath() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        await fixture.service.setRecordingStateForTesting(isRecording: true)

        let counts = await fixture.service.captureFrameCounts()

        // Legacy path with no app capture: a real count for mic, nothing for app.
        #expect(counts.mic == 0)
        #expect(counts.app == nil)
    }

    @Test
    func testFrameCountsReportMicUnavailableUnderRecorderFallback() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: nil,
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav"),
            recorderFallbackActive: true
        )

        let counts = await fixture.service.captureFrameCounts()

        // nil, not 0 — the recorder fallback does not write through AudioFileStreamer, and must
        // never be mistaken for a dead capture.
        #expect(counts.mic == nil)
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
    func testRetargetMicUnderUnifiedCaptureUpdatesLiveStreamWithoutEngineRecovery() async throws {
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
        let state = await fixture.service.recoveryDebugStateForTesting()
        #expect(state.desiredMicDeviceUID == "device-b")
        #expect(!state.isRecoveringMicCapture)
        // The engine path must not run: no restart, and no retry loop scheduled.
        #expect(fixture.micController.startCaptureCalls.isEmpty)
        #expect(!state.hasRecoveryRetryTask)
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
        let state = await fixture.service.recoveryDebugStateForTesting()
        #expect(!state.hasRecoveryRetryTask)
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
        #expect(fixture.micController.startCaptureCalls.isEmpty)
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

    @Test
    func testEngineConfigurationChangeUnderUnifiedCaptureIsANoOp() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 1, uid: "device-a")]

        let unified = makeUnifiedSession(micDeviceUID: "device-a")
        let stream = StubUnifiedStream()
        unified.attachStreamForTesting(stream)
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "device-a",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )
        await fixture.service.setUnifiedCaptureSessionForTesting(unified)

        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()

        // There is no AVAudioEngine to restart on this path.
        #expect(fixture.micController.startCaptureCalls.isEmpty)
        #expect(stream.updateCallCount == 0)
        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.consumePendingError() == nil)
        let state = await fixture.service.recoveryDebugStateForTesting()
        #expect(!state.hasRecoveryRetryTask)
    }

    // MARK: - Capture targeting

    @Test
    func engineCaptureTargetsTheDesiredMicWhileItIsUsable() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(1, "BuiltInMicrophoneDevice"), (2, "airpods:input")]

        try await startEngineCaptureAfterConfigurationChange(fixture, desiredMicDeviceUID: "airpods:input")

        #expect(fixture.micController.startCaptureCalls.last?.deviceID == 2)
    }

    @Test
    func engineCaptureFallsBackToTheSystemInputWhenTheDesiredMicIsDead() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(1, "BuiltInMicrophoneDevice"), (2, "airpods:input")]
        fixture.hardware.deadDeviceIDs = [2]

        try await startEngineCaptureAfterConfigurationChange(fixture, desiredMicDeviceUID: "airpods:input")

        let call = try #require(fixture.micController.startCaptureCalls.last)
        #expect(call.deviceID == nil)
    }

    @Test
    func engineCaptureNeverTargetsAPrivateAggregateOrAnOutputOnlyDevice() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(1, "BuiltInMicrophoneDevice"), (2, "CADefaultDeviceAggregate-74099-0"), (3, "BuiltInSpeakerDevice")]
        fixture.hardware.privateAggregateIDs = [2]
        fixture.hardware.outputOnlyDeviceIDs = [3]

        try await startEngineCaptureAfterConfigurationChange(fixture, desiredMicDeviceUID: "CADefaultDeviceAggregate-74099-0")
        try await startEngineCaptureAfterConfigurationChange(fixture, desiredMicDeviceUID: "BuiltInSpeakerDevice")

        #expect(fixture.micController.startCaptureCalls.map(\.deviceID) == [nil, nil])
    }

    /// Every device is offered exactly when capture would target it.
    @Test
    func theMicListAndCaptureTargetingAgree() async throws {
        let fixture = try await makeRecoveryFixture()
        defer { removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [
            (1, "BuiltInMicrophoneDevice"), (2, "airpods:input"), (3, "CADefaultDeviceAggregate-74099-0"), (4, "BuiltInSpeakerDevice")
        ]
        fixture.hardware.deadDeviceIDs = [2]
        fixture.hardware.privateAggregateIDs = [3]
        fixture.hardware.outputOnlyDeviceIDs = [4]
        let suiteName = "RecordingServiceTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        let deviceService = await MainActor.run {
            AudioDeviceService(
                hardware: fixture.hardware,
                userDefaults: UserDefaults(suiteName: suiteName)!,
                notificationCenter: NotificationCenter()
            )
        }
        let offered = await MainActor.run { Set(deviceService.availableDevices.map(\.uid)) }

        var targeted: Set<String> = []
        for (id, uid) in fixture.hardware.devices {
            try await startEngineCaptureAfterConfigurationChange(fixture, desiredMicDeviceUID: uid)
            if fixture.micController.startCaptureCalls.last?.deviceID == id {
                targeted.insert(uid)
            }
        }

        #expect(offered == ["BuiltInMicrophoneDevice"])
        #expect(targeted == offered)
    }

    private func startEngineCaptureAfterConfigurationChange(
        _ fixture: (service: RecordingService, workspace: Workspace, hardware: MockRecoveryAudioDeviceHardware, micController: MockMicCaptureController),
        desiredMicDeviceUID: String
    ) async throws {
        await fixture.service.setRecordingStateForTesting(isRecording: true, liveAudioContinuation: nil)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: desiredMicDeviceUID,
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )
        fixture.micController.isRunning = false
        await fixture.service.simulateAudioEngineConfigurationChangeForTesting()
    }

    // MARK: - Hung engine start (ticket 09)

    @Test
    func aRetargetWhoseEngineStartHangsReturnsAndSchedulesARetry() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "uid-a"), (id: 22, uid: "uid-b")]
        fixture.engines.hangingDeviceIDs = [22]
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-a",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )

        let finished = await finishes(within: 3) {
            await fixture.service.retargetMic(desiredDeviceUID: "uid-b")
        }

        // The service is held by the blocked start until it is released, so ask nothing more.
        try #require(finished)
        #expect(await fixture.service.isRecording())
        #expect(await fixture.service.recoveryDebugStateForTesting().hasRecoveryRetryTask)
    }

    @Test
    func aHungEngineStartThatReturnsLateIsStoppedWithoutTouchingTheCurrentCapture() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "uid-a"), (id: 22, uid: "uid-b")]
        fixture.engines.hangingDeviceIDs = [22]
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-a",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav"),
            fallbackMicDeviceUID: "uid-a"
        )
        try #require(await finishes(within: 3) { await fixture.service.retargetMic(desiredDeviceUID: "uid-b") })
        await fixture.service.performMicRecoveryRetryAttemptForTesting()
        let hung = try #require(fixture.engines.made.first { $0.hung })
        let current = try #require(fixture.engines.made.last)
        #expect(hung !== current)
        #expect(current.startedDeviceIDs == [11])

        hung.release()

        #expect(await eventually { hung.stopCount > 0 })
        #expect(current.isRunning)
        #expect(current.stopCount == 0)
        #expect(await fixture.service.recoveryDebugStateForTesting().currentCaptureDeviceID == 11)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aDeviceWhoseEngineStartHangsIsNotStartedAgainUntilTheCallReturns() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "uid-a"), (id: 22, uid: "uid-b")]
        fixture.engines.hangingDeviceIDs = [22, 0]
        await fixture.service.setRecordingStateForTesting(isRecording: true)
        await fixture.service.setMicRecoveryStateForTesting(
            desiredMicDeviceUID: "uid-b",
            micFileURL: fixture.workspace.rootURL.appendingPathComponent("mic.wav")
        )

        for _ in 0..<3 {
            try #require(await finishes(within: 3) { await fixture.service.performMicRecoveryRetryAttemptForTesting() })
        }

        #expect(fixture.engines.attemptedDeviceIDs.filter { $0 == 22 }.count == 1)
        #expect(fixture.engines.attemptedDeviceIDs.filter { $0 == nil }.count == 1)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aStopWhileAnEngineRecoveryHangsCompletesAndSavesTheRecording() async throws {
        let fixture = try await makeHangFixture(engineCallTimeout: .seconds(30))
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin")]
        let sessionID = try await fixture.service.startRecording(
            in: fixture.workspace,
            micDeviceID: 11,
            preferredMicDeviceUID: "airpods",
            title: "Session",
            audioSyncFlags: .shippedDefaults
        )
        fixture.engines.hangingDeviceIDs = [22]
        fixture.hardware.devices.append((id: 22, uid: "airpods"))
        let service = fixture.service
        Task { await service.simulateHardwareChangeForTesting() }
        try #require(await eventually { fixture.engines.made.contains { $0.hung } })

        let stopped = StopResult()
        try #require(await finishes(within: 3) { await stopped.set(service.stopRecording()) })

        #expect(await stopped.value == sessionID)
        let session = try fetchRecordingSession(id: sessionID, from: ModelContext(fixture.container))
        #expect(session.status == .recorded)
        let hung = try #require(fixture.engines.made.first { $0.hung })
        hung.release()
        #expect(await eventually { hung.stopCount > 0 })
    }

    @Test
    func startCompletesWhenItsTargetRecheckHangsAndCaptureReturnsToTheStartDevice() async throws {
        let fixture = try await makeHangFixture(engineCallTimeout: .seconds(1))
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin")]
        fixture.engines.hangingDeviceIDs = [22]
        // The preferred mic appears while the start's engine starts, so only the re-check sees it.
        let hardware = fixture.hardware
        fixture.engines.onFirstStart = { hardware.devices.append((id: 22, uid: "airpods")) }

        let started = await finishes(within: 4) {
            _ = try? await fixture.service.startRecording(
                in: fixture.workspace,
                micDeviceID: 11,
                preferredMicDeviceUID: "airpods",
                title: "Session",
                audioSyncFlags: .shippedDefaults
            )
        }

        try #require(started)
        #expect(await fixture.service.isRecording())
        #expect(fixture.engines.made.contains { $0.hung })
        #expect(await eventually {
            await fixture.service.recoveryDebugStateForTesting().currentCaptureDeviceID == 11
                && fixture.engines.made.last?.isRunning == true
        })
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aStartWhoseEngineHangsOnThePreferredMicRecordsOnTheDefault() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin"), (id: 22, uid: "airpods")]
        fixture.engines.hangingDeviceIDs = [22]

        let started = await finishes(within: 3) {
            _ = try? await fixture.service.startRecording(
                in: fixture.workspace,
                micDeviceID: 22,
                preferredMicDeviceUID: "airpods",
                title: "Session",
                audioSyncFlags: .shippedDefaults
            )
        }

        try #require(started)
        #expect(await fixture.service.isRecording())
        #expect(fixture.engines.made.last?.startedDeviceIDs == [nil])
        #expect(fixture.engines.made.last?.isRunning == true)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aStartWhoseEngineHangsOnTheDefaultUsesTheRecorderFallback() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin")]
        fixture.engines.hangingDeviceIDs = [0]

        let started = await finishes(within: 3) {
            _ = try? await fixture.service.startRecording(in: fixture.workspace, title: "Session", audioSyncFlags: .shippedDefaults)
        }

        try #require(started)
        #expect(await fixture.service.isRecording())
        #expect(fixture.recorder.recordCalls == 1)
        #expect(await fixture.service.capturedMicrophone() == .unknown)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aRemovalWhoseDefaultEngineStartHangsReturnsAndSchedulesARetry() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin"), (id: 22, uid: "airpods")]
        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            micDeviceID: 22,
            preferredMicDeviceUID: "airpods",
            title: "Session",
            audioSyncFlags: .shippedDefaults
        )
        fixture.engines.hangingDeviceIDs = [0]
        fixture.hardware.devices = [(id: 11, uid: "builtin")]

        let finished = await finishes(within: 3) { await fixture.service.simulateHardwareChangeForTesting() }

        try #require(finished)
        #expect(fixture.engines.made.last?.hung == true)
        #expect(await fixture.service.recoveryDebugStateForTesting().hasRecoveryRetryTask)
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aResumeWhoseEngineRestartHangsFailsAndKeepsTheRecordingPaused() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin")]
        _ = try await fixture.service.startRecording(
            in: fixture.workspace,
            micDeviceID: 11,
            title: "Session",
            audioSyncFlags: .shippedDefaults
        )
        #expect(await fixture.service.pauseRecording())
        try #require(fixture.engines.made.last).die()
        fixture.engines.hangingDeviceIDs = [11]

        let resumed = ResumeResult()
        try #require(await finishes(within: 3) { await resumed.set(fixture.service.resumeRecording()) })

        #expect(await resumed.value == false)
        #expect(await fixture.service.isPaused())
        _ = await fixture.service.stopRecording()
    }

    @Test
    func aStopWhoseEngineStopHangsCompletesAndSavesTheRecording() async throws {
        let fixture = try await makeHangFixture()
        defer { fixture.engines.releaseAll(); removeWorkspace(at: fixture.workspace.rootURL) }
        fixture.hardware.devices = [(id: 11, uid: "builtin")]
        let sessionID = try await fixture.service.startRecording(
            in: fixture.workspace,
            micDeviceID: 11,
            title: "Session",
            audioSyncFlags: .shippedDefaults
        )
        try #require(fixture.engines.made.last).stopHangs = true

        let stopped = StopResult()
        try #require(await finishes(within: 3) { await stopped.set(fixture.service.stopRecording()) })

        #expect(await stopped.value == sessionID)
        let session = try fetchRecordingSession(id: sessionID, from: ModelContext(fixture.container))
        #expect(session.status == .recorded)
    }

    private func makeHangFixture(engineCallTimeout: Duration = .milliseconds(200)) async throws -> (
        service: RecordingService,
        workspace: Workspace,
        hardware: MockRecoveryAudioDeviceHardware,
        engines: HangingEngines,
        container: ModelContainer,
        recorder: HangTestRecorder
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
        let engines = HangingEngines()
        let recorder = HangTestRecorder()
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: workspaceService,
            modelContainer: container,
            appAudioSettings: appAudioSettings,
            hardware: hardware,
            micCaptureControllerFactory: { engines.make() },
            engineCallTimeout: engineCallTimeout,
            // Other tests' engine notifications on the default center would start recoveries here.
            notificationCenter: NotificationCenter(),
            mixdownCoordinator: MockRecordingMixdownCoordinator(),
            screenVideoMuxer: MockScreenVideoMuxer(),
            permissionChecker: {},
            scopedAccessStarter: { _ in true },
            scopedAccessStopper: { _ in },
            recorderFallbackFactory: { _, _ in recorder },
            // The default reads the setting on the main actor, which other suites keep busy for
            // seconds; the time windows here measure the engine call alone.
            voiceProcessingSetting: { false }
        )
        return (service, workspace, hardware, engines, container, recorder)
    }

    private func makeRecoveryFixture() async throws -> (
        service: RecordingService,
        workspace: Workspace,
        hardware: MockRecoveryAudioDeviceHardware,
        micController: MockMicCaptureController
    ) {
        let workspace = makeWorkspace()
        try FileManager.default.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
        let modelContainer = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let hardware = MockRecoveryAudioDeviceHardware()
        let micController = MockMicCaptureController()
        let appAudioSettings = await MainActor.run { AppAudioSettings() }
        let service = RecordingService(
            workspaceService: MockWorkspaceService(),
            modelContainer: modelContainer,
            appAudioSettings: appAudioSettings,
            hardware: hardware,
            micCaptureController: micController
        )
        return (service, workspace, hardware, micController)
    }
}

// Thread-safe call counter for voice processing setter tests
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

private final class MockMicCaptureController: MicCaptureControlling, @unchecked Sendable {
    struct StartCall {
        let deviceID: AudioDeviceID?
        let targetSampleRate: Double
    }

    var startCaptureError: Error?
    var startCaptureErrors: [Error] = []
    private(set) var startCaptureCalls: [StartCall] = []
    var onBuffer: MicBufferHandler?
    private(set) var stopCaptureCallCount = 0
    var isRunning = false

    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat: AVAudioFormat,
        micFileURL _: URL,
        micStreamer _: AudioFileStreamer,
        gate _: CaptureAudioGate,
        voiceProcessingEnabled _: Bool,
        applyVoiceProcessing _: @Sendable (AVAudioInputNode, Bool) -> Void,
        onFirstHostTime _: @escaping @Sendable (HostNanoseconds) -> Void,
        onBuffer: @escaping MicBufferHandler
    ) throws {
        if !startCaptureErrors.isEmpty {
            throw startCaptureErrors.removeFirst()
        }
        if let startCaptureError {
            throw startCaptureError
        }
        self.onBuffer = onBuffer
        startCaptureCalls.append(.init(deviceID: deviceID, targetSampleRate: targetFormat.sampleRate))
        isRunning = true
    }

    func stopCapture() {
        stopCaptureCallCount += 1
        isRunning = false
    }

    func retargetDevice(_: AudioDeviceID?) throws {}

    func isCaptureRunning() -> Bool {
        isRunning
    }
}

private final class MockRecoveryAudioDeviceHardware: AudioDeviceHardwareProviding, @unchecked Sendable {
    var devices: [(id: AudioDeviceID, uid: String)] = []
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
        case appAudio
    }

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
        case .appAudio(let session):
            lock.withLock { recorded.append(.appAudio) }
            try await session.start(stream: StubUnifiedStream())
        }
    }
}

/// True when `operation` finished within `seconds`. An operation that never returns is left
/// running; the caller is not held by it.
private func finishes(within seconds: Double, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let outcome = OnceFlag()
    return await withCheckedContinuation { continuation in
        Task {
            await operation()
            if outcome.claim() { continuation.resume(returning: true) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if outcome.claim() { continuation.resume(returning: false) }
        }
    }
}

/// True once `condition` holds, checked every 20 ms for up to `seconds`.
private func eventually(within seconds: Double = 3, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private actor StopResult {
    private(set) var value: UUID?
    func set(_ value: UUID?) { self.value = value }
}

private actor ResumeResult {
    private(set) var value: Bool?
    func set(_ value: Bool) { self.value = value }
}

private final class HangTestRecorder: MicRecorderFallback, @unchecked Sendable {
    private let lock = NSLock()
    private var _recordCalls = 0
    var recordCalls: Int { lock.withLock { _recordCalls } }
    func record() -> Bool {
        lock.withLock { _recordCalls += 1 }
        return true
    }
    func pause() {}
    func stop() {}
    func updateMeters() {}
    func averagePower(forChannel _: Int) -> Float { -160 }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Makes a new engine controller for every capture start, the way the app does, and keeps them
/// so tests can see which ones started, hung, or were stopped.
private final class HangingEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var _hangingDeviceIDs: Set<AudioDeviceID> = []
    private var _made: [HangingMicController] = []
    private var _attemptedDeviceIDs: [AudioDeviceID?] = []
    private var _onFirstStart: (@Sendable () -> Void)?

    /// Starts on these devices block until released. 0 stands for the system default.
    var hangingDeviceIDs: Set<AudioDeviceID> {
        get { lock.withLock { _hangingDeviceIDs } }
        set { lock.withLock { _hangingDeviceIDs = newValue } }
    }

    var made: [HangingMicController] {
        lock.withLock { _made }
    }

    /// Every device a start was called for, in order, whether it returned or not.
    var attemptedDeviceIDs: [AudioDeviceID?] {
        lock.withLock { _attemptedDeviceIDs }
    }

    /// Runs inside the first start, before it returns.
    var onFirstStart: (@Sendable () -> Void)? {
        get { lock.withLock { _onFirstStart } }
        set { lock.withLock { _onFirstStart = newValue } }
    }

    func make() -> any MicCaptureControlling {
        let controller = HangingMicController { [weak self] deviceID in
            guard let self else { return false }
            let first = self.lock.withLock {
                self._attemptedDeviceIDs.append(deviceID)
                defer { self._onFirstStart = nil }
                return self._onFirstStart
            }
            first?()
            return self.hangingDeviceIDs.contains(deviceID ?? 0)
        }
        lock.withLock { _made.append(controller) }
        return controller
    }

    func releaseAll() {
        made.forEach { $0.release() }
    }
}

/// An engine controller whose start can block inside the call, as `-[AVAudioEngine inputNode]`
/// did on hardware (spec, test 10).
private final class HangingMicController: MicCaptureControlling, @unchecked Sendable {
    private let hangs: @Sendable (AudioDeviceID?) -> Bool
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _startedDeviceIDs: [AudioDeviceID?] = []
    private var _stopCount = 0
    private var _running = false
    private var _hung = false
    private var _stopHangs = false
    private var _onBuffer: MicBufferHandler?

    init(hangs: @escaping @Sendable (AudioDeviceID?) -> Bool) {
        self.hangs = hangs
    }

    /// Devices whose start returned.
    var startedDeviceIDs: [AudioDeviceID?] { lock.withLock { _startedDeviceIDs } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var isRunning: Bool { lock.withLock { _running } }
    /// True when a start blocked.
    var hung: Bool { lock.withLock { _hung } }
    var onBuffer: MicBufferHandler? { lock.withLock { _onBuffer } }
    /// Stops block until released.
    var stopHangs: Bool {
        get { lock.withLock { _stopHangs } }
        set { lock.withLock { _stopHangs = newValue } }
    }

    /// The engine stops on its own, as on a route change.
    func die() {
        lock.withLock { _running = false }
    }

    func startCapture(
        deviceID: AudioDeviceID?,
        targetFormat _: AVAudioFormat,
        micFileURL _: URL,
        micStreamer _: AudioFileStreamer,
        gate _: CaptureAudioGate,
        voiceProcessingEnabled _: Bool,
        applyVoiceProcessing _: @Sendable (AVAudioInputNode, Bool) -> Void,
        onFirstHostTime _: @escaping @Sendable (HostNanoseconds) -> Void,
        onBuffer: @escaping MicBufferHandler
    ) throws {
        if hangs(deviceID) {
            lock.withLock { _hung = true }
            released.wait()
        }
        lock.withLock {
            _startedDeviceIDs.append(deviceID)
            _onBuffer = onBuffer
            _running = true
        }
    }

    func stopCapture() {
        if stopHangs {
            released.wait()
        }
        lock.withLock {
            _stopCount += 1
            _running = false
        }
    }

    func retargetDevice(_: AudioDeviceID?) throws {}

    func isCaptureRunning() -> Bool { isRunning }

    /// Lets a blocked start return. Safe to call when nothing is blocked.
    func release() {
        released.signal()
    }
}
