import AVFoundation
import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// The cases the removed trim feature covered, as splices that keep the head and drop the tail.
@MainActor
struct SpliceDroppedTailTests {
    @Test(arguments: [false, true])
    func droppingTheTailCutsFilesTranscriptsMarkdownSearchAndTransformInput(video: Bool) async throws {
        let f = try SpliceFixture(video: video)
        let item = JobsViewModel.SessionListItem.recording(f.session)
        let detail = TranscriptDetailViewModel(session: f.session, aiProviderService: makeAIProviderService())
        #expect(JobsViewModel.matches(query: "three", item: item) == .transcript)
        #expect(detail.finalTranscriptText.contains("THREE"))

        let parts = try await f.service().splice(session: f.session, plan: f.droppedTailPlan(), workspace: f.workspace, context: f.context)
        #expect(parts.map(\.id) == [f.session.id])
        #expect(f.session.duration == 75)
        #expect(try Data(contentsOf: f.audioURL) == SpliceFixture.exported(SpliceFixture.audio, 0, 75))
        if video { #expect(try Data(contentsOf: f.videoURL) == SpliceFixture.exported(SpliceFixture.video, 0, 75)) }
        #expect(try Data(contentsOf: f.group().appendingPathComponent("recording.m4a")) == SpliceFixture.audio)
        if video { #expect(try Data(contentsOf: f.group().appendingPathComponent("screen.mov")) == SpliceFixture.video) }
        #expect(f.session.transcript?.fullText == "one two")
        #expect(f.session.retranscript?.fullText == "ONE TWO")
        #expect(f.session.transcript?.segments.map(\.text) == ["one", "two"])
        let markdown = try String(contentsOf: transcriptMarkdownURL(for: f.session), encoding: .utf8)
        #expect(markdown.contains("TWO") && !markdown.contains("THREE"))
        #expect(JobsViewModel.matches(query: "three", item: item) == nil)
        #expect(!detail.finalTranscriptText.contains("THREE"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.workspace.recordingsURL.path) == ["Original"])
        #expect(try f.temporaryPaths().isEmpty)

        let group = try f.group()
        let coordinator = makeCoordinator(f.workspace)
        let result = try await f.service().restore(session: f.session, workspace: f.workspace, context: f.context, coordinator: coordinator)
        #expect(result == SpliceService.RestoreResult())
        #expect(f.session.duration == 120)
        #expect(f.session.spliceGroupID == nil)
        #expect(try Data(contentsOf: f.audioURL) == SpliceFixture.audio)
        if video { #expect(try Data(contentsOf: f.videoURL) == SpliceFixture.video) }
        #expect(f.session.transcript?.fullText == "one two three")
        let restored = try String(contentsOf: transcriptMarkdownURL(for: f.session), encoding: .utf8)
        #expect(restored.contains("THREE"))
        #expect(JobsViewModel.matches(query: "three", item: item) == .transcript)
        #expect(detail.finalTranscriptText.contains("THREE"))
        #expect(!FileManager.default.fileExists(atPath: group.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.workspace.rootURL.path).allSatisfy { !$0.hasPrefix("_") })
    }

    @Test(arguments: [0, -1, 120, 130, Double.nan, Double.infinity, -Double.infinity])
    func aTailCutOutsideTheRecordingIsRejectedWithoutChanges(cut: Double) async throws {
        let f = try SpliceFixture(video: true)
        var plan = f.droppedTailPlan()
        plan.cuts = [cut]
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        await #expect(throws: SpliceError.invalidPlan) {
            _ = try await f.service().splice(session: f.session, plan: plan, workspace: f.workspace, context: f.context)
        }
        #expect(try f.disk() == before)
        #expect(RecordingSessionRecord(f.session) == record)
    }

    @Test
    func droppingTheTailNeedsSpaceForAudioPlusVideo() async throws {
        let f = try SpliceFixture(video: true)
        let before = try f.disk()
        await #expect(throws: SpliceError.insufficientDiskSpace) {
            _ = try await f.service(capacity: Int64(SpliceFixture.audio.count + 1))
                .splice(session: f.session, plan: f.droppedTailPlan(), workspace: f.workspace, context: f.context)
        }
        #expect(try f.disk() == before)
        _ = try await f.service(capacity: Int64(SpliceFixture.audio.count + SpliceFixture.video.count))
            .splice(session: f.session, plan: f.droppedTailPlan(), workspace: f.workspace, context: f.context)
        #expect(f.session.duration == 75)
    }

    @Test(arguments: ["videoExport", "audioInstall", "videoInstall", "save"])
    func aFailedTailDropLeavesEveryFileAndTheSessionUntouched(stage: String) async throws {
        let f = try SpliceFixture(video: true)
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        var files = SpliceFileOperations()
        let realMove = files.move
        var failed = false
        files.move = { source, destination in
            try realMove(source, destination)
            if !failed, (stage == "audioInstall" && destination == f.audioURL) || (stage == "videoInstall" && destination == f.videoURL) {
                failed = true
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let service = f.service(files: files, export: { source, destination, start, end in
            if stage == "videoExport", source.pathExtension == "mov" { throw CocoaError(.fileWriteUnknown) }
            try await SpliceFixture.fakeExport(source, destination, start, end)
        }, save: { context in
            if stage == "save", f.session.spliceGroupID != nil { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        await #expect(throws: CocoaError.self) {
            _ = try await service.splice(session: f.session, plan: f.droppedTailPlan(), workspace: f.workspace, context: f.context)
        }
        #expect(try f.disk() == before)
        #expect(RecordingSessionRecord(f.session) == record)
        #expect(try f.temporaryPaths().isEmpty)
    }

    @Test(arguments: ["move", "save"])
    func aFailedRestoreKeepsBothVersionsAndCanBeRetried(stage: String) async throws {
        let f = try SpliceFixture(video: true)
        _ = try await f.service().splice(session: f.session, plan: f.droppedTailPlan(), workspace: f.workspace, context: f.context)
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        let coordinator = makeCoordinator(f.workspace)
        var files = SpliceFileOperations()
        let realMove = files.move
        var failed = false
        files.move = { source, destination in
            try realMove(source, destination)
            if !failed, stage == "move", destination == f.videoURL {
                failed = true
                throw CocoaError(.fileWriteUnknown)
            }
        }
        await #expect(throws: CocoaError.self) {
            _ = try await f.service(files: files, save: { context in
                if stage == "save" { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            }).restore(session: f.session, workspace: f.workspace, context: f.context, coordinator: coordinator)
        }
        #expect(try f.disk() == before)
        #expect(RecordingSessionRecord(f.session) == record)

        _ = try await f.service().restore(session: f.session, workspace: f.workspace, context: f.context, coordinator: coordinator)
        #expect(f.session.spliceGroupID == nil)
        #expect(try Data(contentsOf: f.audioURL) == SpliceFixture.audio)
        #expect(try Data(contentsOf: f.videoURL) == SpliceFixture.video)
    }

    @Test
    func slicingForADroppedTailKeepsHeadSegmentsAndAnEmptyPassStaysEmpty() {
        let segments = [("kept", Float(10), Float(20)), ("late", 65, 70)].map {
            TranscriptSegment(speakerId: "S1", text: $0.0, startTime: $0.1, endTime: $0.2)
        }
        let pass = Transcript(fullText: Transcript.fullText(joining: segments), segments: segments, speakers: [])
        let head = SpliceService.slice(pass, cuts: [60], originSessionID: UUID())[0]
        #expect(head.segments.map(\.text) == ["kept"])
        #expect(head.fullText == "kept")
        let empty = SpliceService.slice(Transcript(fullText: "", segments: [], speakers: []), cuts: [60], originSessionID: UUID())
        #expect(empty.count == 2)
        #expect(empty.allSatisfy { $0.segments.isEmpty })
    }

    @Test
    func droppingTheTailOfARealRecordingAndRestoringGiveTheExpectedDurations() async throws {
        let f = try SpliceFixture()
        try FileManager.default.removeItem(at: f.audioURL)
        try writeTone(to: f.audioURL, seconds: 5)
        f.session.duration = 5
        let segments = [TranscriptSegment(speakerId: "A", text: "Hello", startTime: 0, endTime: 1.5),
                        TranscriptSegment(speakerId: "A", text: "Late", startTime: 3.5, endTime: 4.5)]
        f.session.transcript = Transcript(fullText: "Hello Late", segments: segments, speakers: [])
        f.session.retranscript = nil
        try f.context.save()
        #expect(SpliceService.cutPoints(transcript: f.session.transcript, retranscript: nil, duration: 5) == [2.5])
        let plan = SplicePlan(cuts: [2.5], parts: [.init(title: "Head"), .init(title: "Tail", isDropped: true)],
                              transcriptFingerprint: f.fingerprint())
        _ = try await f.service(export: SpliceService.exportTimeRange).splice(session: f.session, plan: plan, workspace: f.workspace, context: f.context)
        #expect(abs(try await AVURLAsset(url: f.audioURL).load(.duration).seconds - 2.5) < 0.1)
        #expect(f.session.transcript?.segments.map(\.text) == ["Hello"])

        _ = try await f.service().restore(session: f.session, workspace: f.workspace, context: f.context, coordinator: makeCoordinator(f.workspace))
        #expect(abs(try await AVURLAsset(url: f.audioURL).load(.duration).seconds - 5) < 0.1)
        #expect(f.session.duration == 5)
        #expect(f.session.transcript?.segments.map(\.text) == ["Hello", "Late"])
    }

    private func makeCoordinator(_ workspace: Workspace) -> SessionDeletionCoordinator {
        SessionDeletionCoordinator(workspaceService: ReconciliationWorkspace(workspace: workspace), announce: { _ in },
            startAccess: { _ in false }, stopAccess: { _ in }, scheduleExpiry: { _, _ in AnyCancellable {} })
    }

    private func makeAIProviderService() -> AIProviderService {
        let defaults = UserDefaults(suiteName: "SpliceDroppedTailTests.\(UUID().uuidString)") ?? .standard
        return AIProviderService(keychainStore: MockKeychainStore(), store: AIProviderStore(defaults: defaults))
    }

    private func writeTone(to url: URL, seconds: Double) throws {
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * rate)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = Float(0.5 * sin(2 * .pi * 440 * Double(index) / rate)) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        try file.write(from: buffer)
    }
}

extension SpliceFixture {
    /// Keeps the first two passages and drops the third.
    func droppedTailPlan() -> SplicePlan {
        SplicePlan(cuts: [75], parts: [.init(title: "Kept"), .init(title: "Dropped", isDropped: true)], transcriptFingerprint: fingerprint())
    }
}
