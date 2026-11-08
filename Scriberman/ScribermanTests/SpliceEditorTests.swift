import AppKit
import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Scriberman

@MainActor
struct SpliceEditorTests {
    private func transcript() -> Transcript {
        let segments = [(0, 10), (20, 30), (40, 50), (60, 70)].enumerated().map {
            TranscriptSegment(speakerId: "A", text: "Passage \($0.offset + 1)", startTime: Float($0.element.0), endTime: Float($0.element.1))
        }
        return Transcript(fullText: Transcript.fullText(joining: segments), segments: segments,
                          speakers: [TranscriptSpeaker(id: "A", label: "Alice", colorHex: "112233")])
    }

    private func editor() -> SpliceEditorViewModel {
        SpliceEditorViewModel(title: "Planning", duration: 80, transcript: transcript(), retranscript: nil, fingerprint: Data([1, 2]))
    }

    @Test
    func hoverAndAddSnapToTheNearestFreePoint() {
        let e = editor()
        #expect(e.cutPoints == [15, 35, 55])
        #expect(!e.canApply)
        e.hover(at: 31)
        #expect(e.hoveredCutPoint == 35)
        e.addCut(near: 31)
        #expect(e.cuts.map(\.time) == [35])
        #expect(e.nearestFreePoint(to: 35) == 15)
        e.addCut(near: 55)
        e.addCut(near: 15)
        #expect(e.cuts.map(\.time) == [15, 35, 55])
        #expect(e.nearestFreePoint(to: 40) == nil)
        e.addCut(near: 40)
        #expect(e.cuts.count == 3)
        #expect(e.nearestFreePoint(to: .nan) == nil)
        e.hover(at: nil)
        #expect(e.hoveredCutPoint == nil)
    }

    @Test
    func partsKeepNamesAndFlagsOnTheirEarlierHalfAndEarlierMerge() throws {
        let e = editor()
        let originalID = e.parts[0].id
        e.renamePart(originalID, to: "Custom")
        e.toggleDropped(originalID)
        e.addCut(near: 35)
        #expect(e.parts[0].id == originalID)
        #expect(e.title(at: 0) == "Custom")
        #expect(e.parts[0].isDropped)
        #expect(!e.parts[1].isDropped)
        // The first kept part keeps the original title until the user gives it a title.
        #expect(e.title(at: 1) == "Planning")
        e.renamePart(e.parts[1].id, to: "Later")
        e.addCut(near: 55)
        #expect(e.title(at: 1) == "Later")
        #expect(e.title(at: 2) == "Planning (Part 3)")
        e.toggleDropped(e.parts[1].id)
        let cut = try #require(e.cuts.first)
        e.moveCut(cut.id, near: 15)
        #expect(e.title(at: 0) == "Custom")
        #expect(e.title(at: 1) == "Later")
        #expect(e.parts[0].isDropped && e.parts[1].isDropped)
        e.removeCut(cut.id)
        #expect(e.parts[0].id == originalID)
        #expect(e.title(at: 0) == "Custom")
        #expect(e.parts[0].isDropped)
        #expect(e.parts.count == 2)
    }

    @Test
    func draggingSnapsWithoutCrossingOtherCutsAndIsOneUndoAction() throws {
        let e = editor()
        e.addCut(near: 15)
        e.addCut(near: 55)
        let cut = try #require(e.cuts.first)
        e.beginMovingCut(cut.id)
        e.previewMove(near: 30)
        e.previewMove(near: 54)
        #expect(e.cuts.map(\.time) == [35, 55])
        #expect(!e.canApply)
        e.endMovingCut()
        #expect(e.undoManager.undoActionName == "Move Cut")
        e.undo()
        #expect(e.cuts.map(\.time) == [15, 55])
        e.redo()
        #expect(e.cuts.map(\.time) == [35, 55])
        e.beginMovingCut(cut.id)
        e.previewMove(near: 15)
        e.endMovingCut(remove: true)
        #expect(e.cuts.map(\.time) == [55])
        #expect(e.undoManager.undoActionName == "Remove Cut")
        e.undo()
        #expect(e.cuts.map(\.time) == [35, 55])
    }

    @Test
    func cutsNamesAndDropsUndoAndRedoWithoutTouchingWindowHistory() throws {
        let e = editor()
        let windowHistory = UndoManager()
        #expect(!windowHistory.canUndo)
        e.addCut(near: 15)
        #expect(e.undoManager.undoActionName == "Add Cut")
        let id = e.parts[1].id
        e.renamePart(id, to: "Hiring")
        #expect(e.undoManager.undoActionName == "Part Name")
        e.toggleDropped(id)
        #expect(e.undoManager.undoActionName == "Drop Part")
        e.undo()
        #expect(!e.parts[1].isDropped)
        e.undo()
        #expect(e.title(at: 1) == "Planning (Part 2)")
        e.undo()
        #expect(e.cuts.isEmpty)
        #expect(!e.canUndo)
        e.redo(); e.redo(); e.redo()
        #expect(e.parts[1].isDropped)
        #expect(e.title(at: 1) == "Hiring")
        #expect(!windowHistory.canUndo)
        e.toggleDropped(id)
        #expect(e.undoManager.undoActionName == "Keep Part")
        #expect(!e.canRedo)
    }

    @Test
    func applyRequiresACutAndKeptPartAndKeepsTheFingerprint() {
        let e = editor()
        e.renamePart(e.parts[0].id, to: "Renamed")
        #expect(!e.canApply)
        e.addCut(near: 35)
        #expect(e.canApply)
        #expect(e.plan.transcriptFingerprint == Data([1, 2]))
        #expect(e.plan.parts.map(\.title) == ["Renamed", "Planning (Part 2)"])
        e.toggleDropped(e.parts[0].id)
        e.toggleDropped(e.parts[1].id)
        #expect(!e.canApply)
        e.undo()
        #expect(e.keptCount == 1)
        #expect(e.canApply)
        e.isApplying = true
        #expect(!e.canApply && !e.canUndo && !e.canRedo)
        let plan = e.plan
        e.addCut(near: 15)
        e.renamePart(e.parts[1].id, to: "Blocked")
        e.toggleDropped(e.parts[1].id)
        #expect(e.plan == plan)
    }

    @Test
    func transcriptGapsRemainAvailableInsideSameSpeakerPassages() {
        let pass = transcript()
        #expect(TranscriptGrouper.makeBlocks(from: pass).count == 1)
        let blocks = TranscriptGrouper.makeBlocks(from: pass, breaksAt: editor().cutPoints)
        #expect(blocks.map(\.text) == ["Passage 1", "Passage 2", "Passage 3", "Passage 4"])
        #expect(blocks.map(\.startTime) == [0, 20, 40, 60])
        #expect(blocks.allSatisfy { $0.speaker.label == "Alice" })
    }

    @Test
    func commandAvailabilityRequiresCutPointsWorkspaceAndFinishedScreenMux() {
        func availability(cut: Bool = true, mux: Bool = false, workspace: Bool = true, status: RecordingStatus = .done) -> SessionCommandAvailability {
            SessionCommandAvailability(selection: .recording(status), isRecordingRunning: false,
                isTranscriptShown: true, hasLoadedAudio: true, hasFindTarget: true,
                isSelectionInActiveWorkspace: workspace, hasSpliceCutPoint: cut, hasPendingScreenMux: mux)
        }
        #expect(availability().isEnabled(.splice))
        #expect(!availability(cut: false).isEnabled(.splice))
        #expect(!availability(mux: true).isEnabled(.splice))
        #expect(!availability(workspace: false).isEnabled(.splice))
        #expect(!availability(status: .retranscribing).isEnabled(.splice))
    }

    @Test
    func approvedErrorCopyCoversEverySpliceError() {
        #expect(SpliceCopy.errorMessage(SpliceError.insufficientDiskSpace) == "Not enough disk space to splice this recording")
        #expect(SpliceCopy.errorMessage(SpliceError.stalePlan) == "The transcript changed while you were editing")
        #expect(SpliceCopy.errorMessage(SpliceError.busy) == "Another part of this recording is busy. Try again when it finishes.")
        #expect(SpliceCopy.errorMessage(SpliceError.inactiveWorkspace) == "This session is in another workspace. Switch to that workspace and try again.")
        #expect(SpliceCopy.errorMessage(SpliceError.missingOriginal) == "The original recording files could not be found.")
        #expect(SpliceCopy.errorMessage(CocoaError(.fileWriteUnknown)) == "Something went wrong while writing the files. The recording was not changed.")
    }

    @Test
    func applyingKeepsTheSelectionUntilTheOperationFinishes() {
        let availability = SessionCommandAvailability(
            selection: .recording(.done), isRecordingRunning: false,
            isTranscriptShown: true, hasLoadedAudio: true, hasFindTarget: true,
            isSelectionInActiveWorkspace: true, hasSpliceCutPoint: true,
            isSpliceEditorOpen: true, isApplyingSplice: true
        )
        for command: SessionCommandAvailability.Command in [.newSession, .importFile, .startRecording, .splice, .delete, .reprocess] {
            #expect(!availability.isEnabled(command))
        }
    }

    @Test
    func editingChangesNothingUntilTheProducedPlanIsApplied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(rootURL: root)
        let folder = try RecordingFileLayout.createRecordingFolder(in: workspace, createdAt: .now)
        let audio = folder.appendingPathComponent("recording.m4a")
        let originalBytes = Data("Original media".utf8)
        try originalBytes.write(to: audio)
        let container = try ModelContainer(for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let session = RecordingSession(duration: 80, micAudioURL: folder.appendingPathComponent("mic.wav").path,
                                       mixdownURL: audio.path, title: "Planning", status: .done)
        session.transcript = transcript()
        context.insert(session)
        try context.save()
        let before = RecordingSessionRecord(session)
        let fingerprint = SplicePlan.fingerprint(transcriptData: session.transcriptData, retranscriptData: nil)
        let e = SpliceEditorViewModel(title: session.title, duration: session.duration, transcript: session.transcript, retranscript: nil, fingerprint: fingerprint)
        e.addCut(near: 15); e.addCut(near: 55)
        e.toggleDropped(e.parts[1].id)
        e.renamePart(e.parts[2].id, to: "Customers")
        #expect(RecordingSessionRecord(session) == before)
        #expect(try Data(contentsOf: audio) == originalBytes)
        #expect(try context.fetch(FetchDescriptor<RecordingSession>()).count == 1)
        let service = SpliceService(capacityProvider: { _ in .max }, export: { source, destination, _, _ in
            try Data(contentsOf: source).write(to: destination)
        })
        let parts = try await service.splice(session: session, plan: e.plan, workspace: workspace, context: context)
        #expect(parts.count == 2)
        #expect(parts[0] === session)
        #expect(parts.map(\.title) == ["Planning", "Customers"])
        #expect(parts.map(\.duration) == [15, 25])
        #expect(parts[1].transcript?.segments.first?.startTime == 5)
        #expect(try context.fetch(FetchDescriptor<RecordingSession>()).count == 2)
    }
}

struct WaveformPeakTests {
    @Test
    func peakReaderReturnsBoundedPeaksFromTheWholeRecording() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("recording.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<8_000 { samples[index] = index < 4_000 ? 0 : 0.5 }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let reader = AudioSampleReader(processingChunkSize: 257)
        let peaks = try await reader.peaks(from: url, bucketCount: 20)
        #expect(peaks.count == 20)
        #expect(Array(peaks.prefix(10)) == [Float](repeating: 0, count: 10))
        #expect(Array(peaks.suffix(10)) == [Float](repeating: 1, count: 10))
        #expect(try await reader.peaks(from: url, bucketCount: 0).isEmpty)
    }
}

@MainActor
@Suite(.serialized)
struct SpliceEditorRenderTests {
    @Test
    func cutAndEscapeKeysLeaveTextEditingAndModifiedKeysAlone() async throws {
        var cuts = 0, cancels = 0
        func handler(editing: Bool = false, applying: Bool = false) -> SpliceKeyboardHandler {
            SpliceKeyboardHandler(isEditingText: editing, isApplying: applying,
                                  onCut: { cuts += 1 }, onCancel: { cancels += 1 })
        }
        let host = NSHostingView(rootView: handler())
        host.frame = NSRect(x: 0, y: 0, width: 80, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func key(code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let view = try #require(descendants(host).compactMap { $0 as? SpliceKeyboardHandler.KeyView }.first)
        #expect(view.handle?(try key(code: 8, characters: "c")) == true)
        #expect(view.handle?(try key(code: 53, characters: "\u{1b}")) == true)
        #expect(cuts == 1 && cancels == 1)
        #expect(view.handle?(try key(code: 8, characters: "c", flags: .command)) == false)
        #expect(view.handle?(try key(code: 49, characters: " ")) == false)
        host.rootView = handler(editing: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.handle?(try key(code: 8, characters: "c")) == false)
        #expect(view.handle?(try key(code: 53, characters: "\u{1b}")) == false)
        host.rootView = handler(applying: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(view.handle?(try key(code: 8, characters: "c")) == false)
        #expect(cuts == 1 && cancels == 1)
    }

    @Test
    func renderEditorWithKeptAndDroppedParts() async throws {
        let audioFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioFolder) }
        let audioURL = audioFolder.appendingPathComponent("recording.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960_000))
        buffer.frameLength = buffer.frameCapacity
        let data = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) {
            let envelope = Float(0.2 + 0.8 * abs(sin(Double(i) / 8_000 * 0.7)))
            data[i] = envelope * sin(Float(i) * 0.25)
        }
        do { let file = try AVAudioFile(forWriting: audioURL, settings: format.settings); try file.write(from: buffer) }
        let segments = [(0, 20, "Roadmap and the next release."), (35, 55, "Interview plans for next week."), (75, 100, "Customer feedback and follow-up.")].map {
            TranscriptSegment(speakerId: "A", text: $0.2, startTime: Float($0.0), endTime: Float($0.1))
        }
        let transcript = Transcript(fullText: Transcript.fullText(joining: segments), segments: segments,
                                    speakers: [TranscriptSpeaker(id: "A", label: "Alice", colorHex: "112233")])
        for (width, dark) in [(800.0, false), (800, true), (460, false)] {
            let editor = SpliceEditorViewModel(title: "Planning", duration: 120, transcript: transcript, retranscript: nil, fingerprint: Data())
            editor.addCut(near: 27); editor.addCut(near: 65)
            editor.toggleDropped(editor.parts[1].id)
            let player = AudioPlayerViewModel()
            player.duration = 120; player.currentTime = 18
            let content = VStack(alignment: .leading) {
                Text("Planning").font(.title).padding(.horizontal, 28)
                ScrollView {
                    SpliceTranscriptView(editor: editor, transcript: transcript, player: player).padding(.horizontal, 28)
                }
                SpliceEditorView(editor: editor, player: player, transcript: transcript,
                                 audioURL: audioURL, onCancel: {}, onApply: {})
            }
            .padding(.top, 24)
            .frame(width: width, height: 660)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 660)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            window.displayIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "splice-editor-\(Int(width))-\(dark ? "dark" : "light").png")
            window.orderOut(nil)
        }
    }

    @Test
    func applyTitleUsesTheSingularForOneKeptPart() {
        #expect(SpliceCopy.apply(1) == "Splice into 1 part")
        #expect(SpliceCopy.apply(3) == "Splice into 3 parts")
    }

    @Test
    func undoMenuStateMirrorsTheUndoManagerAndIsDisabledWithoutOne() {
        let state = UndoMenuState(observing: nil)
        state.refresh(from: nil)
        #expect(!state.canUndo && !state.canRedo)
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        // The undo handler registers its inverse, as real edits do, so a redo exists afterwards.
        manager.registerUndo(withTarget: state) { target in manager.registerUndo(withTarget: target) { _ in } }
        manager.setActionName("Speaker Name")
        manager.endUndoGrouping()
        state.refresh(from: manager)
        #expect(state.canUndo && !state.canRedo)
        #expect(state.undoTitle == manager.undoMenuItemTitle)
        #expect(state.undoTitle.contains("Speaker Name"))
        manager.undo()
        state.refresh(from: manager)
        #expect(!state.canUndo && state.canRedo)
        #expect(state.redoTitle == manager.redoMenuItemTitle)
    }

    @Test
    func cutPointCacheRecomputesOnlyWhenThePassesChange() throws {
        let session = RecordingSession(duration: 80, micAudioURL: "/tmp/splice-cache/mic.wav", mixdownURL: "/tmp/splice-cache/recording.m4a", title: "Planning", status: .done)
        let speakers = [TranscriptSpeaker(id: "A", label: "Alice", colorHex: "112233")]
        let gapped = [TranscriptSegment(speakerId: "A", text: "One", startTime: 0, endTime: 10),
                      TranscriptSegment(speakerId: "A", text: "Two", startTime: 20, endTime: 30)]
        session.transcript = Transcript(fullText: "One Two", segments: gapped, speakers: speakers)
        let cache = SpliceCutPointCache()
        #expect(cache.hasCutPoint(session))
        #expect(cache.hasCutPoint(session))
        #expect(cache.computeCount == 1)
        let one = TranscriptSegment(speakerId: "A", text: "Only", startTime: 0, endTime: 80)
        session.transcript = Transcript(fullText: "Only", segments: [one], speakers: speakers)
        #expect(!cache.hasCutPoint(session))
        #expect(cache.computeCount == 2)
    }
}
