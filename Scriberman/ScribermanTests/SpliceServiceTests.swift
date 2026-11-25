import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Scriberman

struct SplicePlanTests {
    private func pass(_ times: [(Float, Float)], source: AudioSource = .mic) -> Transcript {
        let segments = times.enumerated().map { index, time in
            TranscriptSegment(speakerId: "S\(index)", text: "\(index)", startTime: time.0, endTime: time.1, audioSource: source)
        }
        return Transcript(fullText: Transcript.fullText(joining: segments), segments: segments, speakers: [])
    }

    @Test
    @MainActor
    func cutRangesCoverEveryBoundaryOfTheDisplayedPassAndIgnoreMalformedTimes() {
        func ranges(_ first: Transcript, _ second: Transcript? = nil) -> [ClosedRange<Double>] {
            SpliceService.cutRanges(transcript: first, retranscript: second, duration: 60)
        }
        let first = pass([(0, 10), (20, 30), (40, 50), (.nan, 35), (32, 31), (34, .infinity)])
        #expect(ranges(first) == [10...20, 30...40])
        #expect(SpliceService.cutPoints(transcript: first, retranscript: nil, duration: 60) == [15, 35])
        #expect(ranges(first, pass([(8, 22), (25, 30)], source: .app)) == [22...25])
        #expect(ranges(pass([(0, 60)])).isEmpty)
        #expect(ranges(pass([])).isEmpty)
        #expect(ranges(pass([(0, 10), (10, 20)])) == [10...10])
        // Overlapping, inside a longer segment, and starting together.
        #expect(ranges(pass([(0, 12), (10, 20)])) == [10...10])
        #expect(ranges(pass([(0, 30), (5, 8), (9, 12), (40, 50)])) == [5...5, 9...9, 30...40])
        #expect(ranges(pass([(0, 10), (20, 30), (20, 25)])) == [10...20])
        #expect(ranges(pass([(0, 10), (0, 20), (60, 70)])).allSatisfy { $0.upperBound > 0 && $0.upperBound < 60 })
    }

    @Test
    @MainActor
    func validationAcceptsAnyTimeInsideACutRangeOnly() throws {
        let displayed = pass([(0, 10), (20, 30), (28, 40)])
        func validate(_ cuts: [Double]) throws {
            try SpliceService.validate(
                plan: SplicePlan(cuts: cuts, parts: (0...cuts.count).map { .init(title: "\($0)") },
                                 transcriptFingerprint: SplicePlan.fingerprint(transcriptData: nil, retranscriptData: nil)),
                duration: 60, transcript: displayed, retranscript: nil, transcriptData: nil, retranscriptData: nil)
        }
        for cuts in [[10], [11.3], [20], [12, 17, 28]] as [[Double]] { try validate(cuts) }
        for cut in [9.9, 20.1, 29, 45] {
            #expect(throws: SpliceError.invalidPlan) { try validate([cut]) }
        }
    }

    @Test
    @MainActor
    func slicingEndsAnOverlappingSegmentWithItsPart() {
        let parts = SpliceService.slice(pass([(0, 12), (10, 20)]), cuts: [10], originSessionID: UUID())
        #expect(parts[0].segments.map(\.endTime) == [10])
        #expect(parts[0].segments.map(\.text) == ["0"])
        #expect(parts[1].segments.map(\.startTime) == [0])
        #expect(parts[1].segments.map(\.endTime) == [10])
    }

    @Test
    @MainActor
    func slicingPreservesIdentityMetadataAndMalformedSegments() throws {
        let origin = UUID(), profile = UUID()
        var transcript = pass([(1, 3), (11, 14), (17, 16), (.nan, 8), (12, .infinity)])
        transcript.speakers = transcript.segments.enumerated().map {
            TranscriptSpeaker(id: $0.element.speakerId, label: "Name \($0.offset)", colorHex: "112233")
        }
        transcript.speakerVoiceprints = ["S0": [[1], [2]], "S1": [[3]]]
        transcript.speakerProfileIDs = ["S0": profile, "S1": profile]
        transcript.voiceprintSpace = "test-space"
        transcript.isSinglePassOfMixedAudio = true
        let parts = SpliceService.slice(transcript, cuts: [10], originSessionID: origin)
        #expect(parts[0].segments.map(\.text) == ["0", "3"])
        #expect(parts[1].segments.map(\.text) == ["1", "2", "4"])
        #expect(parts[1].segments[0].startTime == 1)
        #expect(parts[1].segments[0].endTime == 4)
        #expect(parts[1].segments[0].id == transcript.segments[1].id)
        #expect(parts[1].segments[1].startTime == 7)
        #expect(parts[1].segments[1].endTime == 6)
        #expect(parts[0].speakerVoiceprints == ["S0": [[1], [2]]])
        #expect(parts[1].speakerProfileIDs == ["S1": profile])
        #expect(parts[1].speakers.map(\.label) == ["Name 1", "Name 2", "Name 4"])
        #expect(parts.allSatisfy { $0.voiceprintSpace == "test-space" && $0.isSinglePassOfMixedAudio == true })
        #expect(parts.allSatisfy { $0.spliceOriginSessionID == origin })
        #expect(SpliceService.slice(parts[1], cuts: [5], originSessionID: UUID()).allSatisfy { $0.spliceOriginSessionID == origin })
        let finitePart = SpliceService.slice(pass([(1, 3), (11, 14)]), cuts: [10], originSessionID: origin)[0]
        #expect(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(finitePart)) == finitePart)
    }

    @Test
    func fingerprintDistinguishesAbsentEmptyAndPassBoundaries() {
        let a = SplicePlan.fingerprint(transcriptData: Data([1]), retranscriptData: Data([2, 3]))
        let b = SplicePlan.fingerprint(transcriptData: Data([1, 2]), retranscriptData: Data([3]))
        #expect(a != b)
        #expect(SplicePlan.fingerprint(transcriptData: nil, retranscriptData: nil)
                != SplicePlan.fingerprint(transcriptData: Data(), retranscriptData: nil))
    }
}

@MainActor
struct SpliceServiceTests {
    @Test(arguments: [false, true])
    func spliceCreatesPartsWithFilesTranscriptsTagsAndOriginals(video: Bool) async throws {
        let f = try SpliceFixture(video: video)
        f.session.capturedAppName = "Zoom"
        f.session.captureInterruptionCount = 2
        f.session.appAudioMissing = true
        let before = RecordingSessionRecord(f.session)
        let parts = try await f.service().splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.capturedAppName == "Zoom" })
        #expect(parts.dropFirst().allSatisfy { $0.captureInterruptionCount == nil && $0.appAudioMissing == nil })
        #expect(parts[0] === f.session)
        #expect(parts.map(\.duration) == [35, 40, 45])
        #expect(parts.map(\.title) == ["First", "Second", "Third"])
        #expect(parts.map(\.createdAt) == [f.start, f.start.addingTimeInterval(35), f.start.addingTimeInterval(75)])
        #expect(parts.allSatisfy { $0.spliceGroupID == parts[0].spliceGroupID && $0.status == .done })
        #expect(parts.allSatisfy { $0.tags.map(\.id) == before.tagIDs })
        #expect(parts[0].aiTransformationsData == before.aiTransformationsData)
        #expect(parts[0].transcriptSegments.map(\.id) == before.transcriptSegments.map(\.id))
        #expect(parts.dropFirst().allSatisfy { $0.aiTransformations.isEmpty && $0.transcriptSegments.isEmpty && $0.appAudioURL == nil })
        let folders = parts.map { URL(fileURLWithPath: $0.micAudioURL).deletingLastPathComponent() }
        #expect(Set(folders).count == 3)
        #expect(parts.dropFirst().allSatisfy { URL(fileURLWithPath: $0.micAudioURL).lastPathComponent == "mic.wav" })
        #expect(parts.dropFirst().allSatisfy { !FileManager.default.fileExists(atPath: $0.micAudioURL) })
        let group = try f.group()
        #expect(try Data(contentsOf: group.appendingPathComponent("recording.m4a")) == SpliceFixture.audio)
        if video { #expect(try Data(contentsOf: group.appendingPathComponent("screen.mov")) == SpliceFixture.video) }
        let manifest = try JSONDecoder().decode(SpliceManifest.self, from: Data(contentsOf: group.appendingPathComponent(SpliceManifest.fileName)))
        #expect(manifest.originalSessionID == before.id)
        #expect(manifest.duration == before.duration)
        #expect(manifest.title == before.title)
        #expect(manifest.createdAt == before.createdAt)
        #expect(manifest.transcriptData == before.transcriptData)
        #expect(manifest.retranscriptData == before.retranscriptData)
        for (index, part) in parts.enumerated() {
            let range = [(0.0, 35.0), (35, 75), (75, 120)][index]
            #expect(try Data(contentsOf: URL(fileURLWithPath: part.mixdownURL!)) == SpliceFixture.exported(SpliceFixture.audio, range.0, range.1))
            if video {
                #expect(try Data(contentsOf: URL(fileURLWithPath: part.screenVideoURL!)) == SpliceFixture.exported(SpliceFixture.video, range.0, range.1))
            } else { #expect(part.screenVideoURL == nil) }
            #expect(part.transcript?.fullText == ["one", "two", "three"][index])
            #expect(part.retranscript?.fullText == ["ONE", "TWO", "THREE"][index])
            #expect(part.searchableText == part.retranscript?.fullText)
            #expect(part.transcript?.spliceOriginSessionID == before.id)
            #expect(part.retranscript?.spliceOriginSessionID == before.id)
            #expect(part.transcript?.segments.first?.startTime == [10, 15, 15][index])
            let markdown = try String(contentsOf: transcriptMarkdownURL(for: part), encoding: .utf8)
            #expect(markdown.contains(["ONE", "TWO", "THREE"][index]))
            #expect(!markdown.contains(["TWO", "THREE", "ONE"][index]))
        }
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 3)
        #expect(try f.temporaryPaths().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: group.appendingPathComponent(SpliceJournal.fileName).path))
    }

    @Test(arguments: [0, 1, 2])
    func droppingHeadMiddleOrTailKeepsTheFirstKeptPartIdentity(drop: Int) async throws {
        let f = try SpliceFixture()
        var plan = f.plan()
        plan.parts[drop].isDropped = true
        let parts = try await f.service().splice(session: f.session, plan: plan, workspace: f.workspace, context: f.context)
        #expect(parts.count == 2)
        #expect(parts[0].id == f.session.id)
        #expect(parts.map(\.title) == ["First", "Second", "Third"].enumerated().filter { $0.offset != drop }.map(\.element))
        #expect(parts[0].createdAt == f.start.addingTimeInterval(drop == 0 ? 35 : 0))
    }

    @Test(arguments: ["nan", "infinity", "negativeInfinity", "zero", "end", "outside", "notGap", "descending", "duplicate", "count", "allDropped", "noOp", "stale"])
    func invalidPlansLeaveFilesAndRecordsUntouched(shape: String) async throws {
        let f = try SpliceFixture(video: true)
        var plan = f.plan()
        switch shape {
        case "nan": plan.cuts[0] = .nan
        case "infinity": plan.cuts[0] = .infinity
        case "negativeInfinity": plan.cuts[0] = -.infinity
        case "zero": plan.cuts[0] = 0
        case "end": plan.cuts[1] = 120
        case "outside": plan.cuts[0] = -1
        case "notGap": plan.cuts[0] = 55
        case "descending": plan.cuts.reverse()
        case "duplicate": plan.cuts[1] = 35
        case "count": plan.parts.removeLast()
        case "allDropped": plan.parts = plan.parts.map { .init(title: $0.title, isDropped: true) }
        case "noOp": plan.cuts = []; plan.parts = [.init(title: f.session.title)]
        default: plan.transcriptFingerprint = Data()
        }
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        await #expect(throws: shape == "stale" ? SpliceError.stalePlan : SpliceError.invalidPlan) {
            _ = try await f.service().splice(session: f.session, plan: plan, workspace: f.workspace, context: f.context)
        }
        #expect(try f.disk() == before)
        #expect(RecordingSessionRecord(f.session) == record)
    }

    @Test(arguments: ["workspace", "status", "mux", "audio", "audioPath", "transcript", "corruptPass", "video", "manifest", "originalAudio", "originalVideo", "legacyTrim"])
    func preconditionsRejectWithoutChanges(reason: String) async throws {
        let f = try SpliceFixture(video: true)
        var workspace = f.workspace
        var expected = SpliceError.missingOriginal
        switch reason {
        case "workspace": workspace = Workspace(rootURL: f.workspace.rootURL.appendingPathComponent("other")); expected = .inactiveWorkspace
        case "status": f.session.status = .recording; expected = .unfinishedRecording
        case "mux": f.session.screenMuxState = "pending"; expected = .unfinishedRecording
        case "audio": try FileManager.default.removeItem(at: f.audioURL); expected = .missingMixdown
        case "audioPath": f.session.mixdownURL = nil; expected = .missingMixdown
        case "transcript": f.session.transcriptData = nil; f.session.retranscriptData = nil; expected = .missingTranscript
        case "corruptPass": f.session.transcriptData = Data([0]); expected = .missingTranscript
        case "video": try FileManager.default.removeItem(at: f.videoURL)
        case "legacyTrim": f.session.originalMixdownURL = "old"; expected = .requiresTrimMigration
        default:
            var initial = f.plan()
            initial.cuts = [75]
            initial.parts = [.init(title: "First two"), .init(title: "Third")]
            _ = try await f.service().splice(session: f.session, plan: initial, workspace: workspace, context: f.context)
            let group = try f.group()
            let name = reason == "manifest" ? SpliceManifest.fileName : (reason == "originalAudio" ? "recording.m4a" : "screen.mov")
            try FileManager.default.removeItem(at: group.appendingPathComponent(name))
        }
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        await #expect(throws: expected) {
            _ = try await f.service().splice(session: f.session, plan: f.plan(), workspace: workspace, context: f.context)
        }
        #expect(try f.disk() == before)
        #expect(RecordingSessionRecord(f.session) == record)
    }

    @Test
    func capacityIncludesVideoAndUnknownCapacityIsRefused() async throws {
        let f = try SpliceFixture(video: true)
        let before = try f.disk()
        for available in [nil, Int64(SpliceFixture.audio.count)] {
            await #expect(throws: SpliceError.insufficientDiskSpace) {
                _ = try await f.service(capacity: available).splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
            }
            #expect(try f.disk() == before)
        }
        _ = try await f.service(capacity: Int64(SpliceFixture.audio.count + SpliceFixture.video.count))
            .splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
    }

    @Test(arguments: ["audioExport", "videoExport", "originalMove", "manifest", "newPart", "markdown", "save"])
    func failuresRollBackFilesRecordsAndUnrelatedPendingChangesSurvive(stage: String) async throws {
        let f = try SpliceFixture(video: true)
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        let unrelated = RecordingSession(duration: 1, micAudioURL: "unrelated", title: "Pending edit")
        f.context.insert(unrelated)
        var files = SpliceFileOperations()
        let realMove = files.move, realWrite = files.write
        var failed = false
        files.move = { source, destination in
            try realMove(source, destination)
            if !failed && ((stage == "originalMove" && destination.path.contains("/splice/"))
                || (stage == "newPart" && destination.path.contains("/recordings/") && destination.deletingLastPathComponent() != f.folder)) {
                failed = true
                throw CocoaError(.fileWriteUnknown)
            }
        }
        files.write = { data, url in
            try realWrite(data, url)
            if !failed && ((stage == "manifest" && url.lastPathComponent == SpliceManifest.fileName)
                || (stage == "markdown" && url == transcriptMarkdownURL(for: f.session))) {
                failed = true
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let service = f.service(files: files, export: { source, destination, start, end in
            if (stage == "audioExport" && source.pathExtension == "m4a") || (stage == "videoExport" && source.pathExtension == "mov") {
                try Data("partial".utf8).write(to: destination)
                throw CocoaError(.fileWriteUnknown)
            }
            try await SpliceFixture.fakeExport(source, destination, start, end)
        }, save: { context in
            if stage == "save", f.session.spliceGroupID != nil { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        await #expect(throws: CocoaError.self) {
            _ = try await service.splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        }
        #expect(try f.disk() == before)
        #expect(RecordingSessionRecord(f.session) == record)
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 2)
        let fresh = ModelContext(f.container)
        #expect(try RecordingSession.fetch(id: unrelated.id, in: fresh)?.title == "Pending edit")
        #expect(try f.temporaryPaths().isEmpty)
    }

    @Test
    func rollbackFailureKeepsTheJournalAndOriginalMedia() async throws {
        let f = try SpliceFixture()
        var files = SpliceFileOperations()
        let realMove = files.move
        files.move = { source, destination in
            if source.path.contains("/splice/") { throw CocoaError(.fileWriteUnknown) }
            try realMove(source, destination)
            if destination.path.contains("/splice/") { throw CocoaError(.fileWriteUnknown) }
        }
        await #expect(throws: CocoaError.self) {
            _ = try await f.service(files: files).splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        }
        let groups = try FileManager.default.contentsOfDirectory(at: f.workspace.rootURL.appendingPathComponent("splice"), includingPropertiesForKeys: nil)
        let group = try #require(groups.first)
        #expect(try Data(contentsOf: group.appendingPathComponent("recording.m4a")) == SpliceFixture.audio)
        let journal = try JSONDecoder().decode(SpliceJournal.self, from: Data(contentsOf: group.appendingPathComponent(SpliceJournal.fileName)))
        #expect(journal.originalRecord.id == f.session.id)
        #expect(journal.results.count == 3)
        #expect(journal.moves.count == 4)
        #expect(journal.previousMarkdown == (try f.disk()["recordings/Original/transcript.md"]))
        #expect(f.session.spliceGroupID == nil)
    }

    @Test
    func resplicingKeepsOriginalGroupBytesAndOrigin() async throws {
        let f = try SpliceFixture(video: true)
        var first = f.plan()
        first.cuts = [75]
        first.parts = [.init(title: "First two"), .init(title: "Third")]
        _ = try await f.service().splice(session: f.session, plan: first, workspace: f.workspace, context: f.context)
        let group = try f.group(), originalBytes = try f.groupBytes()
        let second = SplicePlan(cuts: [35], parts: [.init(title: "One"), .init(title: "Two")], transcriptFingerprint: f.fingerprint())
        let parts = try await f.service().splice(session: f.session, plan: second, workspace: f.workspace, context: f.context)
        #expect(parts.count == 2)
        #expect(try f.group() == group)
        #expect(try f.groupBytes() == originalBytes)
        #expect(parts.allSatisfy { $0.transcript?.spliceOriginSessionID == f.session.id })
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 3)
    }

    @Test
    func failedResplicePreservesTheExistingGroupAndEveryPart() async throws {
        let f = try SpliceFixture(video: true)
        var initial = f.plan()
        initial.cuts = [75]
        initial.parts = [.init(title: "First two"), .init(title: "Third")]
        _ = try await f.service().splice(session: f.session, plan: initial, workspace: f.workspace, context: f.context)
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        await #expect(throws: CocoaError.self) {
            _ = try await f.service(save: { _ in throw CocoaError(.fileWriteUnknown) })
                .splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        }
        #expect(try f.disk() == before)
        #expect(RecordingSessionRecord(f.session) == record)
        #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).count == 2)
    }

    @Test
    func changedTranscriptRejectsTheEditorsOldFingerprint() async throws {
        let f = try SpliceFixture()
        let oldPlan = f.plan()
        var updated = try #require(f.session.retranscript)
        updated.fullText = "Edited text"
        f.session.retranscript = updated
        let before = try f.disk(), record = RecordingSessionRecord(f.session)
        await #expect(throws: SpliceError.stalePlan) {
            _ = try await f.service().splice(session: f.session, plan: oldPlan, workspace: f.workspace, context: f.context)
        }
        #expect(RecordingSessionRecord(f.session) == record)
        #expect(try f.disk() == before)
    }

    @Test
    func sourceEditDuringExportIsRefusedWithoutDiscardingTheEdit() async throws {
        let f = try SpliceFixture()
        let before = try f.disk()
        let service = f.service(export: { source, destination, start, end in
            try await SpliceFixture.fakeExport(source, destination, start, end)
            f.session.title = "Edited during export"
        })
        await #expect(throws: SpliceError.stalePlan) {
            _ = try await service.splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        }
        #expect(f.session.title == "Edited during export")
        #expect(try f.disk() == before)
    }

    @Test
    func anotherServiceCannotSpliceTheReservedSession() async throws {
        let f = try SpliceFixture()
        var checked = false
        let service = f.service(export: { source, destination, start, end in
            if !checked {
                checked = true
                await #expect(throws: SpliceError.busy) {
                    _ = try await f.service().splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
                }
            }
            try await SpliceFixture.fakeExport(source, destination, start, end)
        })
        _ = try await service.splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        #expect(checked)
    }

    @Test
    func journalCleanupFailureKeepsTheCommittedParts() async throws {
        let f = try SpliceFixture()
        var files = SpliceFileOperations()
        let remove = files.remove
        files.remove = { url in
            if url.lastPathComponent == SpliceJournal.fileName { throw CocoaError(.fileWriteUnknown) }
            try remove(url)
        }
        let parts = try await f.service(files: files).splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        #expect(parts.count == 3)
        let fresh = ModelContext(f.container)
        #expect(try fresh.fetch(FetchDescriptor<RecordingSession>()).count == 3)
        let journalURL = try f.group().appendingPathComponent(SpliceJournal.fileName)
        let journal = try JSONDecoder().decode(SpliceJournal.self, from: Data(contentsOf: journalURL))
        for result in journal.results {
            let saved = try #require(try RecordingSession.fetch(id: result.sessionID, in: fresh))
            #expect(saved.transcriptData == result.transcriptData)
            #expect(saved.retranscriptData == result.retranscriptData)
            #expect(saved.duration == result.duration)
            #expect(saved.createdAt == result.createdAt)
            #expect(saved.title == result.title)
        }
    }
}

@MainActor
final class SpliceFixture {
    static let audio = Data("original audio".utf8)
    static let video = Data("original video".utf8)
    let workspace: Workspace
    let container: ModelContainer
    let context: ModelContext
    let session: RecordingSession
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let folder: URL
    var audioURL: URL { folder.appendingPathComponent("recording.m4a") }
    var videoURL: URL { folder.appendingPathComponent("screen.mov") }

    init(video: Bool = false) throws {
        workspace = Workspace(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        folder = workspace.recordingsURL.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        container = try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        context.autosaveEnabled = false
        session = RecordingSession(
            createdAt: start, duration: 120, micAudioURL: folder.appendingPathComponent("mic.wav").path,
            screenVideoURL: video ? folder.appendingPathComponent("screen.mov").path : nil,
            mixdownURL: folder.appendingPathComponent("recording.m4a").path, title: "Original", status: .done
        )
        context.insert(session)
        let tag = RecordingTag(name: "Work", colorHex: "112233")
        context.insert(tag)
        session.tags = [tag]
        let segments = [("A", "one", Float(10), Float(20)), ("B", "two", 50, 60), ("A", "three", 90, 100)].map {
            TranscriptSegment(speakerId: $0.0, text: $0.1, startTime: $0.2, endTime: $0.3)
        }
        var transcript = Transcript(
            fullText: Transcript.fullText(joining: segments), segments: segments,
            speakers: [TranscriptSpeaker(id: "A", label: "Alice", colorHex: "112233"), TranscriptSpeaker(id: "B", label: "Bob", colorHex: "445566")],
            speakerEmbeddings: ["A": [1, 0], "B": [0, 1]], speakerProfileIDs: ["A": UUID(), "B": UUID()], voiceprintSpace: "test"
        )
        session.transcript = transcript
        transcript.segments = segments.map {
            TranscriptSegment(speakerId: $0.speakerId, text: $0.text.uppercased(), startTime: $0.startTime, endTime: $0.endTime, audioSource: .app)
        }
        transcript.fullText = Transcript.fullText(joining: transcript.segments)
        session.retranscript = transcript
        session.aiTransformations = [AITransformation(promptName: "Summary", modelID: "test", resultText: "Prior result")]
        session.transcriptSegments = [RecordingTranscriptSegment(speakerId: "live", text: "Original live text", startTime: 1, endTime: 2, audioSource: .mic)]
        try Self.audio.write(to: folder.appendingPathComponent("recording.m4a"))
        if video { try Self.video.write(to: folder.appendingPathComponent("screen.mov")) }
        try writeTranscriptMarkdown(for: session)
        try context.save()
    }

    deinit { try? FileManager.default.removeItem(at: workspace.rootURL) }

    func fingerprint() -> Data {
        SplicePlan.fingerprint(transcriptData: session.transcriptData, retranscriptData: session.retranscriptData)
    }

    func plan() -> SplicePlan {
        let cuts = SpliceService.cutPoints(transcript: session.transcript, retranscript: session.retranscript, duration: session.duration)
        let titles = ["First", "Second", "Third"]
        return SplicePlan(cuts: cuts, parts: (0...cuts.count).map { .init(title: titles[$0]) }, transcriptFingerprint: fingerprint())
    }

    static func exported(_ data: Data, _ start: Double, _ end: Double) -> Data {
        Data("\(start)..\(end):".utf8) + data
    }

    static let fakeExport: SpliceService.Export = { source, destination, start, end in
        try exported(Data(contentsOf: source), start, end).write(to: destination)
    }

    func service(
        capacity: Int64? = .max, files: SpliceFileOperations = SpliceFileOperations(),
        export: SpliceService.Export? = nil, save: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) -> SpliceService {
        SpliceService(files: files, capacityProvider: { _ in capacity }, export: export ?? Self.fakeExport, saveContext: save)
    }

    func group() throws -> URL {
        try SpliceService.groupFolder(#require(session.spliceGroupID), workspace: workspace)
    }

    func disk() throws -> [String: Data] {
        let root = workspace.rootURL
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var bytes: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            bytes[String(url.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: url)
        }
        return bytes
    }

    func groupBytes() throws -> [String: Data] {
        try disk().filter { $0.key.hasPrefix("splice/") }
    }

    func temporaryPaths() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: workspace.rootURL.path).filter { $0.hasPrefix("_splice_") }
    }
}

@MainActor
struct SpliceMediaExportTests {
    @Test
    func nonzeroAudioRangeHasTheRequestedDurationAndContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.m4a"), output = folder.appendingPathComponent("part.m4a")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(4 * rate)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = index < Int(rate) ? 0 : Float(0.5 * sin(2 * .pi * 440 * Double(index) / rate))
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
            ])
            try file.write(from: buffer)
        }
        try await SpliceService.exportTimeRange(from: source, to: output, start: 1.23, end: 3.47)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        print("Splice AAC range 1.23...3.47: duration=\(duration), error=\(abs(duration - 2.24))")
        // Measured duration error: 0 s for this 44.1 kHz AAC fixture at 1.23...3.47.
        // The 50 ms bound covers two AAC packets (2 * 1024 / 44100 s).
        #expect(abs(duration - 2.24) < 0.05)
        let decoded = try AVAudioFile(forReading: output)
        let beginning = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 4_410))
        try decoded.read(into: beginning)
        let data = try #require(beginning.floatChannelData?[0])
        let count = Int(beginning.frameLength)
        #expect(count > 0)
        let energy = (0..<count).reduce(0.0) { $0 + Double(data[$1] * data[$1]) } / Double(count)
        #expect(energy > 0.05)
    }

    @Test
    func nonzeroScreenRangeHasTheRequestedDurationAndContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("screen.mov"), output = folder.appendingPathComponent("part.mov")
        try await writeVideo(to: source)
        try await SpliceService.exportTimeRange(from: source, to: output, start: 1.23, end: 3.47)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        print("Splice H.264 range 1.23...3.47: duration=\(duration), error=\(abs(duration - 2.24))")
        // Measured duration error: 0 s for this 30 fps H.264 fixture at 1.23...3.47.
        // The 50 ms bound covers one frame (1 / 30 s).
        #expect(abs(duration - 2.24) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(decoded)
        #expect(reader.startReading())
        let sample = try #require(decoded.copyNextSampleBuffer())
        let pixel = try #require(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let bytes = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        // Source is red for its first second, then blue. The nonzero export begins in blue.
        #expect(bytes[0] > 200)
        #expect(bytes[2] < 40)
    }

    private func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<120 {
            var pixel: CVPixelBuffer?
            #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let data = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            for row in 0..<32 {
                for col in 0..<32 {
                    let index = row * CVPixelBufferGetBytesPerRow(buffer) + col * 4
                    data[index] = frame < 30 ? 0 : 255
                    data[index + 1] = 0
                    data[index + 2] = frame < 30 ? 255 : 0
                    data[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let deadline = ContinuousClock.now + .seconds(10)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, ContinuousClock.now < deadline else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(2))
            }
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        if let error = writer.error { throw error }
    }
}
