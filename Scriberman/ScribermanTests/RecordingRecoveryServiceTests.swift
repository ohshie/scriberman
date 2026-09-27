import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Scriberman

private actor CallTracker {
    var called = false
    func markCalled() { called = true }
}

private actor CapturedValue {
    private(set) var value: Int?
    func set(_ newValue: Int) { value = newValue }
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
        mixdownAttemptCount: Int = 0,
        createdAt: Date = .now
    ) -> RecordingSession {
        let session = RecordingSession(
            createdAt: createdAt,
            duration: 10,
            micAudioURL: micAudioURL,
            mixdownURL: mixdownURL,
            title: "Test",
            status: status,
            mixdownAttemptCount: mixdownAttemptCount
        )
        return session
    }

    // MARK: - Stale .recording normalization (crash-recovery-hardening)

    @Test
    func testLiveRecordingSessionIsNeverNormalized() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Created after launchedAt: could be genuinely recording right now.
        let session = makeSession(status: .recording, createdAt: .now)
        context.insert(session)
        try context.save()

        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let tracker = CallTracker()
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            launchedAt: Date(timeIntervalSinceNow: -300),
            performMixdown: { _, _, _ in await tracker.markCalled() }
        )

        await service.sweepIncompleteSessions()

        #expect(!(await tracker.called))
        let fetched = try context.fetch(FetchDescriptor<RecordingSession>())
        #expect(fetched.first?.status == .recording)
    }

    @Test
    func testStaleRecordingWithAudioIsNormalizedAndRecovered() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let micPath = tmpDir.appendingPathComponent("mic.wav").path
        FileManager.default.createFile(atPath: micPath, contents: Data())

        let container = try makeContainer()
        let context = ModelContext(container)
        // Created before launchedAt: crash-interrupted by definition.
        let session = makeSession(
            micAudioURL: micPath,
            status: .recording,
            createdAt: Date(timeIntervalSinceNow: -600)
        )
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
        let fetched = try readContext.fetch(FetchDescriptor<RecordingSession>())
        let recovered = try #require(fetched.first(where: { $0.id == sessionID }))
        #expect(recovered.status == .recorded)
        #expect(recovered.mixdownURL != nil)
    }

    @Test
    func testStaleRecordingWithoutAudioBecomesError() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(
            micAudioURL: "/nonexistent/\(UUID().uuidString)/mic.wav",
            status: .recording,
            createdAt: Date(timeIntervalSinceNow: -600)
        )
        context.insert(session)
        try context.save()
        let sessionID = session.id

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
        let readContext = ModelContext(container)
        let fetched = try readContext.fetch(FetchDescriptor<RecordingSession>())
        let result = try #require(fetched.first(where: { $0.id == sessionID }))
        if case .error(let message) = result.status {
            #expect(message.contains("interrupted"))
        } else {
            Issue.record("Expected .error status, got \(result.status)")
        }
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

    @Test(arguments: ["Recording Mar 28 at 14-30 a3", "2026-03-28 14-30"])
    func testRecoveryMixesIntoTheSessionFolderInEitherNameFormat(folderName: String) async throws {
        let workspace = makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.rootURL) }
        let folder = workspace.recordingsURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let micPath = folder.appendingPathComponent("mic.wav").path
        FileManager.default.createFile(atPath: micPath, contents: Data())

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: micPath)
        context.insert(session)
        try context.save()

        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { _, _, _ in }
        )

        await service.sweepIncompleteSessions()

        let recovered = try #require(try RecordingSession.fetch(id: session.id, in: ModelContext(container)))
        #expect(recovered.mixdownURL == folder.appendingPathComponent("recording.m4a").path)
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

    // MARK: - WAV header repair integration (crash-recovery-hardening)

    @Test
    func testStaleWavHeaderIsRepairedBeforeMixdownRuns() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Canonical 44-byte-header mono PCM WAV with crash-stale sizes
        // (RIFF size 36, data size 0) followed by 3,200 payload bytes.
        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(36).littleEndian) { Array($0) })
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(16_000).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(32_000).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
        wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
        wav.append(Data("data".utf8))
        wav.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        wav.append(Data(repeating: 0x22, count: 3_200))

        let micURL = tmpDir.appendingPathComponent("mic.wav")
        try wav.write(to: micURL)

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: micURL.path)
        context.insert(session)
        try context.save()

        let observedDataSize = CapturedValue()
        let workspace = makeWorkspace()
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace
        let service = RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: { micURL, _, _ in
                // Read the header the mixdown would see: repair must have
                // already rewritten the data-chunk size at offset 40.
                let bytes = try Data(contentsOf: micURL)
                let size = UInt32(bytes[40])
                    | (UInt32(bytes[41]) << 8)
                    | (UInt32(bytes[42]) << 16)
                    | (UInt32(bytes[43]) << 24)
                await observedDataSize.set(Int(size))
            }
        )

        await service.sweepIncompleteSessions()

        #expect(await observedDataSize.value == 3_200)
    }

    // MARK: - Helpers

    // MARK: - Finalization recovery (recording-finalization-safety)

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A short AAC file that `AVAudioFile` opens with a positive length.
    private func writeValidMixdown(at url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1]
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        try file.write(from: buffer)
    }

    private func makeRecoveryService(
        container: ModelContainer,
        performMixdown: @escaping RecordingRecoveryService.MixdownHandler = { _, _, _ in },
        performMux: RecordingRecoveryService.MuxHandler? = nil,
        isFinalizing: @escaping @Sendable (UUID) -> Bool = { _ in false }
    ) -> RecordingRecoveryService {
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = makeWorkspace()
        return RecordingRecoveryService(
            workspaceService: workspaceService,
            modelContainer: container,
            performMixdown: performMixdown,
            performMux: performMux ?? { _ in },
            isFinalizing: isFinalizing
        )
    }

    private func fetch(_ id: UUID, in container: ModelContainer) throws -> RecordingSession {
        try #require(try RecordingSession.fetch(id: id, in: ModelContext(container)))
    }

    @Test
    func testRelaunchWithOnlyRecordingM4AAdoptsIt() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixdownURL = folder.appendingPathComponent("recording.m4a")
        try writeValidMixdown(at: mixdownURL)

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: folder.appendingPathComponent("mic.wav").path, status: .recorded)
        context.insert(session)
        try context.save()

        let tracker = CallTracker()
        let service = makeRecoveryService(container: container, performMixdown: { _, _, _ in await tracker.markCalled() })
        await service.sweepIncompleteSessions()

        let recovered = try fetch(session.id, in: container)
        #expect(recovered.mixdownURL == mixdownURL.path)
        #expect(recovered.status == .recorded)
        #expect(!(await tracker.called))
    }

    @Test
    func testUnreadableRecordingM4AFallsBackToMixingRawInputs() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let micURL = folder.appendingPathComponent("mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("wav".utf8))
        FileManager.default.createFile(atPath: folder.appendingPathComponent("recording.m4a").path, contents: Data("not audio".utf8))

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: micURL.path, status: .recorded)
        context.insert(session)
        try context.save()

        let tracker = CallTracker()
        let service = makeRecoveryService(container: container, performMixdown: { _, _, _ in await tracker.markCalled() })
        await service.sweepIncompleteSessions()

        #expect(await tracker.called)
        #expect(try fetch(session.id, in: container).mixdownURL != nil)
    }

    @Test
    func testFailedScreenMuxSucceedsOnTheNextSweep() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixdownURL = folder.appendingPathComponent("recording.m4a")
        try writeValidMixdown(at: mixdownURL)
        let screenTmpURL = RecordingFileLayout.screenTmpVideoURL(in: folder)
        FileManager.default.createFile(atPath: screenTmpURL.path, contents: Data("video".utf8))

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: folder.appendingPathComponent("mic.wav").path, mixdownURL: mixdownURL.path)
        session.screenMuxState = ScreenMuxState.failed.rawValue
        session.videoStartHostTimeNanos = 2_000_000_000
        session.audioAnchorHostTimeNanos = 1_000_000_000
        context.insert(session)
        try context.save()

        let exporter = FailOnceExporter()
        let muxer = ScreenVideoMuxer(workspaceService: MockWorkspaceService(), modelContainer: container, exporter: exporter)
        let service = makeRecoveryService(container: container, performMux: { await muxer.runMux(request: $0) })

        await service.sweepIncompleteSessions()
        var refreshed = try fetch(session.id, in: container)
        #expect(refreshed.screenMuxState == ScreenMuxState.failed.rawValue)
        #expect(refreshed.screenMuxAttemptCount == 1)
        #expect(FileManager.default.fileExists(atPath: screenTmpURL.path))

        await service.sweepIncompleteSessions()
        refreshed = try fetch(session.id, in: container)
        #expect(refreshed.screenMuxState == nil)
        #expect(refreshed.screenVideoURL == RecordingFileLayout.screenVideoURL(in: folder).path)
        #expect(!FileManager.default.fileExists(atPath: screenTmpURL.path))
        let plan = try #require(exporter.lastPlan)
        #expect(plan.audioInstructions.map(\.url) == [mixdownURL])
    }

    @Test
    func testScreenMuxRetriesStopAtTheLimit() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixdownURL = folder.appendingPathComponent("recording.m4a")
        try writeValidMixdown(at: mixdownURL)
        FileManager.default.createFile(atPath: RecordingFileLayout.screenTmpVideoURL(in: folder).path, contents: Data("video".utf8))

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: folder.appendingPathComponent("mic.wav").path, mixdownURL: mixdownURL.path)
        session.screenMuxState = ScreenMuxState.pending.rawValue
        session.videoStartHostTimeNanos = 2_000_000_000
        session.screenMuxAttemptCount = RecordingRecoveryService.maxScreenMuxAttempts
        context.insert(session)
        try context.save()

        let tracker = CallTracker()
        let service = makeRecoveryService(container: container, performMux: { _ in await tracker.markCalled() })
        await service.sweepIncompleteSessions()

        #expect(!(await tracker.called))
    }

    @Test
    func testLeftoverSourcesAreRetiredForACommittedMixdown() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mixdownURL = folder.appendingPathComponent("recording.m4a")
        try writeValidMixdown(at: mixdownURL)
        let micURL = folder.appendingPathComponent("mic.wav")
        let appURL = folder.appendingPathComponent("app.wav")
        for url in [micURL, appURL, AudioFileStreamer.timingSidecarURL(for: micURL), AudioFileStreamer.timingSidecarURL(for: appURL)] {
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: micURL.path, mixdownURL: mixdownURL.path)
        session.appAudioURL = appURL.path
        context.insert(session)
        try context.save()

        await makeRecoveryService(container: container).sweepIncompleteSessions()

        #expect(!RecordingSourceFiles.anyExist(micURL: micURL, appURL: appURL))
        #expect(FileManager.default.fileExists(atPath: mixdownURL.path))
    }

    @Test
    func testSessionStillBeingFinalizedIsLeftAlone() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let micURL = folder.appendingPathComponent("mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("wav".utf8))

        let container = try makeContainer()
        let context = ModelContext(container)
        let session = makeSession(micAudioURL: micURL.path, status: .recorded)
        context.insert(session)
        try context.save()
        let sessionID = session.id

        let tracker = CallTracker()
        let service = makeRecoveryService(
            container: container,
            performMixdown: { _, _, _ in await tracker.markCalled() },
            isFinalizing: { $0 == sessionID }
        )
        await service.sweepIncompleteSessions()

        #expect(!(await tracker.called))
        #expect(FileManager.default.fileExists(atPath: micURL.path))
    }

    private func makeWorkspace() -> Workspace {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Workspace(rootURL: url)
    }
}

/// Fails the first export, then writes the output file.
private final class FailOnceExporter: ScreenVideoExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var exports = 0
    private var plan: ScreenVideoMuxPlan?

    var lastPlan: ScreenVideoMuxPlan? {
        lock.lock()
        defer { lock.unlock() }
        return plan
    }

    func export(plan: ScreenVideoMuxPlan) async throws {
        let attempt = lock.withLock {
            exports += 1
            self.plan = plan
            return exports
        }
        if attempt == 1 {
            throw CocoaError(.fileWriteUnknown)
        }
        FileManager.default.createFile(atPath: plan.request.screenVideoURL.path, contents: Data("mov".utf8))
    }
}
