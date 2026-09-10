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
