import CoreMedia
import Foundation
import SwiftData
import Testing
@testable import Scriberman

final class ScreenVideoMuxerTests {
    private let temporaryDirectoryURL: URL

    init() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
    }

    @Test
    func testMakeAudioInstructionsSelectsMicAndAppSources() throws {
        let micURL = temporaryDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = temporaryDirectoryURL.appendingPathComponent("app.wav")
        _ = FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        _ = FileManager.default.createFile(atPath: appURL.path, contents: Data("app".utf8))

        let instructions = ScreenVideoMuxer.makeAudioInstructions(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 2_000),
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_000)
        )

        #expect(instructions.map(\.label) == ["mic", "app"])
    }

    @Test
    func testOffsetIsCorrectOnANonUnitTimebase() throws {
        let micURL = temporaryDirectoryURL.appendingPathComponent("mic.wav")
        _ = FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let timebase = HostClock.Timebase(numer: 125, denom: 3)

        // Video at 1 s and audio at 1.5 s, both read as Mach ticks at 125/3.
        let instructions = ScreenVideoMuxer.makeAudioInstructions(
            micURL: micURL,
            appURL: nil,
            micStartHostTime: HostNanoseconds(machTicks: 36_000_000, timebase: timebase),
            appStartHostTime: nil,
            videoStartHostTime: HostNanoseconds(machTicks: 24_000_000, timebase: timebase)
        )

        let instruction = try #require(instructions.first)
        #expect(instruction.sourceStart == .zero)
        #expect(CMTimeGetSeconds(instruction.insertionTime) == 0.5)
    }

    @Test
    func testMakeTimelineAudioInstructionsMuxesSingleAnchoredTrack() throws {
        let mixdownURL = temporaryDirectoryURL.appendingPathComponent("recording.m4a")

        // Anchor 0.5s after video start -> single "mixdown" track inserted at +0.5s.
        let instructions = ScreenVideoMuxer.makeTimelineAudioInstructions(
            timelineAudioURL: mixdownURL,
            audioAnchorHostTime: HostNanoseconds(nanoseconds: 1_500_000_000),
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000)
        )

        #expect(instructions.map(\.label) == ["mixdown"])
        let instruction = try #require(instructions.first)
        #expect(instruction.url == mixdownURL)
        #expect(instruction.sourceStart == .zero)
        #expect(CMTimeGetSeconds(instruction.insertionTime) == 0.5)
    }

    @Test
    func testMakeTimelineAudioInstructionsHandlesAudioBeforeVideo() throws {
        let mixdownURL = temporaryDirectoryURL.appendingPathComponent("recording.m4a")

        // Anchor 0.5s before video start -> trim source, insert at zero.
        let instructions = ScreenVideoMuxer.makeTimelineAudioInstructions(
            timelineAudioURL: mixdownURL,
            audioAnchorHostTime: HostNanoseconds(nanoseconds: 500_000_000),
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000)
        )

        let instruction = try #require(instructions.first)
        #expect(instruction.insertionTime == .zero)
        #expect(CMTimeGetSeconds(instruction.sourceStart) == 0.5)
    }

    @Test
    func testMakeAudioInstructionsSupportsAppOnlyAndMicOnly() throws {
        let micURL = temporaryDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = temporaryDirectoryURL.appendingPathComponent("app.wav")
        _ = FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        _ = FileManager.default.createFile(atPath: appURL.path, contents: Data("app".utf8))

        let micOnly = ScreenVideoMuxer.makeAudioInstructions(
            micURL: micURL,
            appURL: nil,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000),
            appStartHostTime: nil,
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_000)
        )
        let appOnly = ScreenVideoMuxer.makeAudioInstructions(
            micURL: temporaryDirectoryURL.appendingPathComponent("missing.wav"),
            appURL: appURL,
            micStartHostTime: nil,
            appStartHostTime: HostNanoseconds(nanoseconds: 2_000),
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_000)
        )

        #expect(micOnly.map(\.label) == ["mic"])
        #expect(appOnly.map(\.label) == ["app"])
    }

    @Test
    func testMakeAudioInstructionsAlignsAroundVideoStart() throws {
        let micURL = temporaryDirectoryURL.appendingPathComponent("mic.wav")
        let appURL = temporaryDirectoryURL.appendingPathComponent("app.wav")
        _ = FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        _ = FileManager.default.createFile(atPath: appURL.path, contents: Data("app".utf8))

        let instructions = ScreenVideoMuxer.makeAudioInstructions(
            micURL: micURL,
            appURL: appURL,
            micStartHostTime: HostNanoseconds(nanoseconds: 500_000_000),
            appStartHostTime: HostNanoseconds(nanoseconds: 1_500_000_000),
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_000_000_000)
        )

        let micInstruction = try #require(instructions.first(where: { $0.label == "mic" }))
        let appInstruction = try #require(instructions.first(where: { $0.label == "app" }))

        #expect(abs(micInstruction.sourceStart.seconds - 0.5) < 0.01)
        #expect(micInstruction.insertionTime == .zero)
        #expect(micInstruction.url == micURL)

        #expect(appInstruction.sourceStart == .zero)
        #expect(abs(appInstruction.insertionTime.seconds - 0.5) < 0.01)
        #expect(appInstruction.url == appURL)
    }

    @Test
    func testRunMuxFailureLeavesSessionUntouchedAndDeletesTmpVideo() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let session = RecordingSession(
            createdAt: .now,
            duration: 12,
            micAudioURL: temporaryDirectoryURL.appendingPathComponent("mic.wav").path,
            title: "Session",
            status: .recorded
        )
        context.insert(session)
        try context.save()

        let request = try makeRequest(sessionID: session.id)
        let muxer = ScreenVideoMuxer(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            exporter: MockScreenVideoExporter(mode: .fail)
        )

        await muxer.runMux(request: request)

        let refreshed = try fetchSession(id: session.id, container: container)
        #expect(refreshed.screenVideoURL == nil)
        #expect(!FileManager.default.fileExists(atPath: request.screenTmpURL.path))
    }

    @Test
    func testRunMuxSuccessPersistsScreenVideoURL() async throws {
        let container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let session = RecordingSession(
            createdAt: .now,
            duration: 12,
            micAudioURL: temporaryDirectoryURL.appendingPathComponent("mic.wav").path,
            title: "Session",
            status: .recorded
        )
        context.insert(session)
        try context.save()

        let request = try makeRequest(sessionID: session.id)
        let muxer = ScreenVideoMuxer(
            workspaceService: MockWorkspaceService(),
            modelContainer: container,
            exporter: MockScreenVideoExporter(mode: .succeed)
        )

        await muxer.runMux(request: request)

        let refreshed = try fetchSession(id: session.id, container: container)
        #expect(refreshed.screenVideoURL == request.screenVideoURL.path)
        #expect(FileManager.default.fileExists(atPath: request.screenVideoURL.path))
        #expect(!FileManager.default.fileExists(atPath: request.screenTmpURL.path))
    }

    private func fetchSession(id: UUID, container: ModelContainer) throws -> RecordingSession {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<RecordingSession>()
        return try #require(context.fetch(descriptor).first(where: { $0.id == id }))
    }

    private func makeRequest(sessionID: UUID) throws -> ScreenVideoMuxRequest {
        let micURL = temporaryDirectoryURL.appendingPathComponent("mic.wav")
        let tmpURL = temporaryDirectoryURL.appendingPathComponent("screen-tmp.mov")
        let screenURL = temporaryDirectoryURL.appendingPathComponent("screen.mov")
        _ = FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        _ = FileManager.default.createFile(atPath: tmpURL.path, contents: Data("tmp".utf8))

        return ScreenVideoMuxRequest(
            sessionID: sessionID,
            screenTmpURL: tmpURL,
            screenVideoURL: screenURL,
            micURL: micURL,
            appURL: nil,
            micStartHostTime: HostNanoseconds(nanoseconds: 1_000),
            appStartHostTime: nil,
            videoStartHostTime: HostNanoseconds(nanoseconds: 1_000)
        )
    }
}

private struct MockScreenVideoExporter: ScreenVideoExporting {
    enum Mode {
        case succeed
        case fail
    }

    let mode: Mode

    func export(plan: ScreenVideoMuxPlan) async throws {
        switch mode {
        case .succeed:
            _ = FileManager.default.createFile(
                atPath: plan.request.screenVideoURL.path,
                contents: Data("screen".utf8)
            )
        case .fail:
            throw RecordingError.failedToStart("forced mux failure")
        }
    }
}
