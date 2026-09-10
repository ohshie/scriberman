import Foundation
import Testing
@testable import Scriberman

/// The live transcript and the finished one are the same words in the same card, and a passage can
/// be copied from either.
struct TranscriptRowTests {
    private func source(_ relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent(relativePathFromTests),
            encoding: .utf8
        )
    }

    private func liveViewSource() throws -> String {
        try source("../UI/ActiveRecordingDetailView.swift")
    }

    private func rowSource() throws -> String {
        try source("../UI/TranscriptRowView.swift")
    }

    // MARK: - One card, two views

    @Test
    func testBothViewsDrawTheSharedRow() throws {
        let block = try source("../UI/TranscriptBlockView.swift")
        let live = try liveViewSource()

        #expect(block.contains("TranscriptRowView("))
        #expect(live.contains("TranscriptRowView(copyText: segment.text)"))
        // The live view's own hand-rolled row is gone.
        #expect(!live.contains("Text(segment.text)\n                                            .font(.callout)"))
    }

    /// Diarization runs after the recording, so a live segment names its source where a finished
    /// block names its speaker. It must not show an empty speaker or invent one.
    @Test
    func testALiveSegmentNamesItsSourceAndNoSpeaker() throws {
        let live = try liveViewSource()

        #expect(live.contains("segment.audioSource == .mic ? \"Mic\" : \"App\""))
        // No speaker anywhere in what it draws — the identity slot holds the source and nothing
        // constructs or reads a speaker here.
        #expect(!live.contains("TranscriptSpeaker"))
        #expect(!live.contains("speaker.label"))
        #expect(!live.contains("segment.speakerId"))
    }

    /// The finished block keeps everything the shared card does not own: seeking, renaming, search.
    @Test
    func testTheFinishedBlockKeepsItsOwnBehaviour() throws {
        let block = try source("../UI/TranscriptBlockView.swift")

        #expect(block.contains(".onTapGesture {\n            onTap()"))
        #expect(block.contains("isEditingSpeaker"))
        #expect(block.contains("highlightedText()"))
    }

    // MARK: - Reaching the text

    @Test
    func testLiveTextIsSelectable() throws {
        let live = try liveViewSource()

        #expect(live.contains(".textSelection(.enabled)"))
    }

    /// A segment arriving must not pull the text out from under someone reading it.
    @Test
    func testANewSegmentDoesNotScrollWhileThePointerIsInTheTranscript() throws {
        let live = try liveViewSource()

        #expect(live.contains("isPointerOverSegments = hovering"))
        #expect(live.contains("guard !isPointerOverSegments else { return }"))
    }

    /// One scrolling region in the window, not two. Segments sit in the view's own flow, so
    /// arriving text pushes the Stop button and the source cards down rather than filling a pane.
    @Test
    func testTheRecordingViewHasASingleScroll() throws {
        let live = try liveViewSource()

        #expect(live.components(separatedBy: "ScrollView {").count - 1 == 1)
        #expect(!live.contains(".frame(height: 120)"))
        #expect(!live.contains(".containerRelativeFrame(.vertical"))
        // The segments are in the same VStack as the controls below them.
        let segments = try #require(live.range(of: "ForEach(viewModel.liveSegments"))
        let stop = try #require(live.range(of: "HeroCircleButton("))
        #expect(segments.lowerBound < stop.lowerBound)
    }

    /// Following the transcript scrolls to the foot of the view, which is where Stop is — so the
    /// newest text and the button that ends the recording stay together.
    @Test
    func testFollowingTheTranscriptKeepsStopInView() throws {
        let live = try liveViewSource()

        #expect(live.contains("proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)"))
        #expect(live.contains(".id(Self.bottomAnchor)"))
        let anchor = try #require(live.range(of: ".id(Self.bottomAnchor)"))
        let stop = try #require(live.range(of: "HeroCircleButton("))
        #expect(anchor.lowerBound > stop.lowerBound)
    }

    // MARK: - Copying one passage

    @Test
    func testTheCopyControlIsOnlyShownUnderThePointer() throws {
        let row = try rowSource()

        #expect(row.contains("if isHovering {"))
        #expect(row.contains(".onHover { hovering in"))
    }

    @Test
    func testTheCopyControlCopiesTheTextAlone() throws {
        let row = try rowSource()

        #expect(row.contains("pasteboard.setString(copyText, forType: .string)"))
        // Not the speaker, not the time — the metadata a quotation would have to have deleted.
        #expect(!row.contains("setString(\"\\(timeText)"))
        #expect(row.contains(".help(\"Copy\")"))
        #expect(row.contains(".accessibilityLabel(\"Copy\")"))
    }

    /// A tap on a finished block seeks and plays; the copy control inside it must not.
    @Test
    func testCopyingDoesNotSeekOrPlay() throws {
        let row = try rowSource()

        #expect(row.contains("Button {\n                        copy()"))
        #expect(!row.contains("player"))
        #expect(!row.contains(".play()"))
    }

    /// A live segment has nothing to seek to, so it carries no time and no source icon — its
    /// identity already says where the audio came from.
    @Test
    func testALiveRowCarriesNoTimeOrDuplicateSourceIcon() throws {
        let row = try rowSource()

        #expect(row.contains("var timeText: String?"))
        #expect(row.contains("var audioSource: AudioSource?"))
        #expect(row.contains("if let timeText {"))
        #expect(row.contains("if let audioSource {"))
    }
}
