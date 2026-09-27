import Foundation
import Testing
@testable import Scriberman

@Suite
struct RecordingFinalizerTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingFinalizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private var micURL: URL { folder.appendingPathComponent("mic.wav") }
    private var appURL: URL { folder.appendingPathComponent("app.wav") }

    private func writeSources() {
        for url in [micURL, appURL] {
            _ = FileManager.default.createFile(atPath: url.path, contents: Data("wav".utf8))
            _ = FileManager.default.createFile(atPath: AudioFileStreamer.timingSidecarURL(for: url).path, contents: Data("timing".utf8))
        }
    }

    private func sourcesExist() -> [Bool] {
        RecordingSourceFiles.sourceURLs(micURL: micURL, appURL: appURL).map { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func makeJob(withMux: Bool = false) -> RecordingFinalizationJob {
        let sessionID = UUID()
        return RecordingFinalizationJob(
            sessionID: sessionID,
            micURL: micURL,
            appURL: appURL,
            mixdownURL: folder.appendingPathComponent("recording.m4a"),
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 2_000),
            screenMux: withMux ? ScreenVideoMuxRequest(
                sessionID: sessionID,
                screenTmpURL: folder.appendingPathComponent("screen-tmp.mov"),
                screenVideoURL: folder.appendingPathComponent("screen.mov"),
                micURL: micURL,
                appURL: appURL,
                micStartHostTime: HostNanoseconds(nanoseconds: 1_000),
                appStartHostTime: HostNanoseconds(nanoseconds: 2_000),
                videoStartHostTime: HostNanoseconds(nanoseconds: 1_500)
            ) : nil
        )
    }

    @Test
    func waitForAllReturnsWhenTheJobCompletes() async {
        let coordinator = FakeMixdownCoordinator(committed: false, gated: true)
        let finalizer = RecordingFinalizer(mixdownCoordinator: coordinator, screenVideoMuxer: FakeMuxer())

        await finalizer.schedule(makeJob())
        #expect(finalizer.hasJobs)

        let wait = Task { await finalizer.waitForAll(timeout: .seconds(10)) }
        await coordinator.release()

        #expect(await wait.value)
        #expect(!finalizer.hasJobs)
    }

    @Test
    func waitForAllReturnsWhenTheTimeoutPasses() async {
        let coordinator = FakeMixdownCoordinator(committed: false, gated: true)
        let finalizer = RecordingFinalizer(mixdownCoordinator: coordinator, screenVideoMuxer: FakeMuxer())

        await finalizer.schedule(makeJob())
        let finished = await finalizer.waitForAll(timeout: .milliseconds(50))

        #expect(!finished)
        #expect(finalizer.hasJobs)
        await coordinator.release()
        #expect(await finalizer.waitForAll(timeout: .seconds(10)))
    }

    @Test
    func waitForAllWithNoJobsReturnsImmediately() async {
        let finalizer = RecordingFinalizer(mixdownCoordinator: FakeMixdownCoordinator(committed: true), screenVideoMuxer: FakeMuxer())
        #expect(!finalizer.hasJobs)
        #expect(await finalizer.waitForAll(timeout: .seconds(10)))
    }

    @Test
    func legacyMuxSeesBothWAVsAndSourcesAreRetiredAfterIt() async {
        writeSources()
        let muxer = FakeMuxer()
        let finalizer = RecordingFinalizer(mixdownCoordinator: FakeMixdownCoordinator(committed: true), screenVideoMuxer: muxer)

        await finalizer.schedule(makeJob(withMux: true))
        #expect(await finalizer.waitForAll(timeout: .seconds(10)))

        #expect(await muxer.observedSourcesPresent == [true])
        #expect(sourcesExist() == [false, false, false, false])
    }

    @Test
    func sourcesStayWhenTheMixdownIsNotCommitted() async {
        writeSources()
        let finalizer = RecordingFinalizer(mixdownCoordinator: FakeMixdownCoordinator(committed: false), screenVideoMuxer: FakeMuxer())

        await finalizer.schedule(makeJob(withMux: true))
        #expect(await finalizer.waitForAll(timeout: .seconds(10)))

        #expect(sourcesExist() == [true, true, true, true])
    }

    @Test
    func failedRetirementKeepsTheSources() async {
        writeSources()
        let finalizer = RecordingFinalizer(
            mixdownCoordinator: FakeMixdownCoordinator(committed: true),
            screenVideoMuxer: FakeMuxer(),
            retireSources: { _, _ in throw CocoaError(.fileWriteNoPermission) }
        )

        await finalizer.schedule(makeJob())
        #expect(await finalizer.waitForAll(timeout: .seconds(10)))

        #expect(sourcesExist() == [true, true, true, true])
    }
}

private actor FakeMixdownCoordinator: RecordingMixdownCoordinating {
    private let committed: Bool
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(committed: Bool, gated: Bool = false) {
        self.committed = committed
        self.isOpen = !gated
    }

    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func runMixdown(
        sessionID _: UUID,
        micURL _: URL,
        appURL _: URL?,
        mixdownURL _: URL,
        micStartHostTime _: HostNanoseconds,
        appStartHostTime _: HostNanoseconds?
    ) async -> Bool {
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return committed
    }
}

/// Records whether both raw WAVs were on disk when each mux ran.
private actor FakeMuxer: ScreenVideoMuxing {
    private(set) var observedSourcesPresent: [Bool] = []

    func runMux(request: ScreenVideoMuxRequest) async {
        let urls = [request.micURL] + [request.appURL].compactMap { $0 }
        observedSourcesPresent.append(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
}
