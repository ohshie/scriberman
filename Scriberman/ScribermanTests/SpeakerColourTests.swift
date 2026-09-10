import Foundation
import Testing
@testable import Scriberman

/// Two speakers in one conversation is the ordinary case, and it was drawn in one colour: the live
/// path gave every speaker the same system blue, and every recording made before that was fixed
/// still carries it.
struct SpeakerColourTests {
    private func transcript(speakerCount: Int, storedHex: String = "#007AFF") -> Transcript {
        let speakers = (0..<speakerCount).map {
            TranscriptSpeaker(id: "speaker_\($0)", label: "Speaker \($0 + 1)", colorHex: storedHex)
        }
        let segments = (0..<speakerCount).map { index in
            TranscriptSegment(
                speakerId: "speaker_\(index)",
                text: "Line \(index)",
                startTime: Float(index),
                endTime: Float(index) + 1
            )
        }
        return Transcript(fullText: "", segments: segments, speakers: speakers)
    }

    @Test
    func testTwoSpeakersAreDrawnInDifferentColours() {
        let blocks = TranscriptGrouper.makeBlocks(from: transcript(speakerCount: 2))

        #expect(blocks.count == 2)
        #expect(blocks[0].speaker.colorHex != blocks[1].speaker.colorHex)
    }

    /// The fix reaches transcripts already on disk: their stored colour is ignored in favour of the
    /// speaker's position, so nothing has to be rewritten.
    @Test
    func testAStoredSingleColourTranscriptIsStillDrawnInSeveral() {
        let blocks = TranscriptGrouper.makeBlocks(from: transcript(speakerCount: 3, storedHex: "#007AFF"))
        let colours = Set(blocks.map(\.speaker.colorHex))

        #expect(colours.count == 3)
        #expect(!colours.contains("#007AFF"))
    }

    @Test
    func testASpeakerKeepsOneColourAcrossBlocks() {
        let speakers = [
            TranscriptSpeaker(id: "a", label: "Speaker 1", colorHex: "#007AFF"),
            TranscriptSpeaker(id: "b", label: "Speaker 2", colorHex: "#007AFF"),
        ]
        let segments = [
            TranscriptSegment(speakerId: "a", text: "first", startTime: 0, endTime: 1),
            TranscriptSegment(speakerId: "b", text: "second", startTime: 1, endTime: 2),
            TranscriptSegment(speakerId: "a", text: "third", startTime: 2, endTime: 3),
        ]
        let blocks = TranscriptGrouper.makeBlocks(
            from: Transcript(fullText: "", segments: segments, speakers: speakers)
        )

        #expect(blocks.count == 3)
        #expect(blocks[0].speaker.colorHex == blocks[2].speaker.colorHex)
        #expect(blocks[0].speaker.colorHex != blocks[1].speaker.colorHex)
    }

    @Test
    func testMoreSpeakersThanColoursRepeatsWithoutAdjacentClashes() {
        let count = SpeakerPalette.colorHexes.count + 2
        let hexes = (0..<count).map { SpeakerPalette.colorHex(at: $0) }

        for index in 1..<count {
            #expect(hexes[index] != hexes[index - 1])
        }
        #expect(hexes[0] == hexes[SpeakerPalette.colorHexes.count])
    }

    // MARK: - Tags in Settings

    /// Tags were the fifth section of General, below the fold at the window's default size — and
    /// the assignment menu's "Add new tag" sent people exactly there.
    @Test
    func testTagsHaveTheirOwnSettingsTab() throws {
        let source = try settingsSource()

        #expect(source.contains("case tags"))
        #expect(source.contains("Label(\"Tags\", systemImage: \"tag\")"))
        #expect(source.contains(".tag(SettingsTab.tags)"))
    }

    @Test
    func testAddingATagFromASessionAsksForTheTagsTab() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let menu = try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TagAssignmentMenu.swift"),
            encoding: .utf8
        )

        #expect(menu.contains("appState.requestedSettingsTab = .tags"))
        #expect(menu.contains("openSettings()"))
    }

    @Test
    func testSettingsHonoursARequestedTabAndClearsIt() throws {
        let source = try settingsSource()

        #expect(source.contains("if let requested = appState.requestedSettingsTab {"))
        #expect(source.contains("appState.requestedSettingsTab = nil"))
    }

    private func settingsSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/SettingsView.swift"),
            encoding: .utf8
        )
    }

    // MARK: - The title says it can be edited

    /// A cue that exists only under the pointer tells nobody anything — and a session named after
    /// its own timestamp is the title most worth renaming.
    @Test
    func testTheEditCueIsPresentAtRest() throws {
        let source = try modifierSource()

        // The pencil is not inside an `if isHovering`: it is always in the overlay, quietened.
        #expect(!source.contains("if isHovering {\n                    Label(\"Edit\""))
        #expect(source.contains(".opacity(isHovering ? 1 : 0.45)"))
    }

    @Test
    func testHoverStillRevealsTheFullTreatment() throws {
        let source = try modifierSource()

        #expect(source.contains(".fill(.ultraThinMaterial)"))
        #expect(source.contains(".opacity(isHovering ? 1 : 0)"))
        #expect(source.contains("stroke(.tint.opacity(isHovering ? 0.35 : 0)"))
        #expect(source.contains(".animation(.easeInOut(duration: 0.2), value: isHovering)"))
    }

    /// The modifier imposes no font or alignment, which is what lets one cue serve a centered
    /// title2 and a leading largeTitle — recordings and imports alike.
    @Test
    func testTheCueImposesNoFontOrAlignment() throws {
        let source = try modifierSource()

        #expect(!source.contains(".font(.largeTitle"))
        #expect(!source.contains(".multilineTextAlignment("))
    }

    private func modifierSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/EditableTitleHoverModifier.swift"),
            encoding: .utf8
        )
    }

    // MARK: - The way into the full transcript

    /// The study view is the app's only full reader, and the only way in was a click anywhere on
    /// the preview card, hinted at by a hover ring under a line reporting a limit.
    @Test
    func testThePreviewOffersALabelledControlIntoTheStudyView() throws {
        let source = try previewSource()

        #expect(source.contains("Button(\"Read full transcript\", action: onTap)"))
        // The count keeps the control company rather than standing in its place.
        #expect(!source.contains("Showing \\(previewBlocks.count) of"))
        #expect(source.contains("Text(\"\\(blocks.count) sections\")"))
    }

    /// A card that opens a different view when clicked is a gesture people already use; the control
    /// is added beside it, not in place of it.
    @Test
    func testThePreviewCardStillOpensTheStudyViewWhenClicked() throws {
        let source = try previewSource()

        #expect(source.contains(".onTapGesture {"))
        #expect(source.contains("onTap?()"))
    }

    /// No control where there is nowhere to go: the preview renders without one when it is not
    /// given a destination.
    @Test
    func testNoControlIsShownWhenThePreviewHasNoDestination() throws {
        let source = try previewSource()

        #expect(source.contains("if let onTap {"))
    }

    private func previewSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TranscriptPreviewView.swift"),
            encoding: .utf8
        )
    }

    // MARK: - Segment times

    /// A block showed `00:00:10,240 - 00:00:40,448` — subtitle-editor precision, in a view built
    /// for reading, stating the same boundary as the next block.
    @Test
    func testABlockShowsItsStartTimeAtSecondResolution() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(
            contentsOf: testsDirectory.appendingPathComponent("../UI/TranscriptBlockView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("TimeFormatter.displayFormat(seconds: block.startTime)"))
        #expect(!source.contains("formatWithMilliseconds"))
        #expect(!source.contains("block.endTime))"))
    }

    @Test
    func testDisplayedStartTimesReadAsExpected() {
        #expect(TimeFormatter.displayFormat(seconds: 10.24) == "0:10")
        #expect(TimeFormatter.displayFormat(seconds: 3_731.9) == "1:02:11")
    }

    /// Precision belongs where it is consumed: the export still writes it.
    @Test
    func testExportStillWritesFullPrecisionTimes() {
        #expect(TimeFormatter.formatWithMilliseconds(seconds: 10.24) == "00:00:10,240")
    }

    /// One palette, because there are three writers of `TranscriptSpeaker` and they disagreed.
    @Test
    func testEveryWriterUsesTheSharedPalette() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for path in [
            "../ViewModels/NewSessionViewModel.swift",
            "../Helpers/TranscriptAligner.swift",
        ] {
            let source = try String(
                contentsOf: testsDirectory.appendingPathComponent(path),
                encoding: .utf8
            )
            #expect(source.contains("SpeakerPalette.colorHex(at:"))
            #expect(!source.contains("#007AFF"))
        }
    }
}
