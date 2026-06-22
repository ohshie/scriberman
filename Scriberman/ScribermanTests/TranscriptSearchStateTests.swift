import Foundation
import Testing
@testable import Scriberman

@MainActor
struct TranscriptSearchStateTests {
    private let speaker = TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")

    @Test
    func updateComputesMatchesCaseAndDiacriticInsensitiveAcrossBlocks() {
        let firstBlock = makeBlock(id: "11111111-1111-1111-1111-111111111111", text: "Cafe")
        let secondBlock = makeBlock(id: "22222222-2222-2222-2222-222222222222", text: "One café here")
        let state = TranscriptSearchState()

        state.query = "CAFÉ"
        state.update(blocks: [firstBlock, secondBlock])

        #expect(state.matches.count == 2)
        #expect(state.currentMatch?.blockID == firstBlock.id)
        #expect(String(firstBlock.text[state.matches[0].range]) == "Cafe")
        #expect(String(secondBlock.text[state.matches[1].range]) == "café")
        #expect(state.summary == "1 of 2")
    }

    @Test
    func updateClearsMatchesForEmptyQuery() {
        let block = makeBlock(id: "33333333-3333-3333-3333-333333333333", text: "Transcript text")
        let state = TranscriptSearchState()

        state.query = "text"
        state.update(blocks: [block])
        state.query = ""
        state.update(blocks: [block])

        #expect(state.matches.isEmpty)
        #expect(state.currentMatch == nil)
        #expect(state.summary.isEmpty)
        #expect(state.currentIndex == 0)
    }

    @Test
    func updateCapturesMultipleMatchesWithinSingleBlock() {
        let block = makeBlock(id: "44444444-4444-4444-4444-444444444444", text: "echo echo ECHO")
        let state = TranscriptSearchState()

        state.query = "echo"
        state.update(blocks: [block])

        #expect(state.matches.count == 3)
        #expect(state.ranges(in: block).count == 3)
        #expect(String(block.text[state.matches[2].range]) == "ECHO")
    }

    @Test
    func navigationWrapsForwardAndBackward() {
        let firstBlock = makeBlock(id: "55555555-5555-5555-5555-555555555555", text: "match")
        let secondBlock = makeBlock(id: "66666666-6666-6666-6666-666666666666", text: "match")
        let state = TranscriptSearchState()

        state.query = "match"
        state.update(blocks: [firstBlock, secondBlock])

        state.next()
        #expect(state.currentMatch?.blockID == secondBlock.id)
        #expect(state.summary == "2 of 2")

        state.next()
        #expect(state.currentMatch?.blockID == firstBlock.id)
        #expect(state.summary == "1 of 2")

        state.previous()
        #expect(state.currentMatch?.blockID == secondBlock.id)
        #expect(state.activeRange(in: secondBlock) != nil)
        #expect(state.activeRange(in: firstBlock) == nil)
    }

    @Test
    func summaryIsEmptyWithoutMatches() {
        let state = TranscriptSearchState()

        #expect(state.summary.isEmpty)
    }

    private func makeBlock(id: String, text: String) -> TranscriptBlock {
        TranscriptBlock(
            id: UUID(uuidString: id)!,
            speaker: speaker,
            audioSource: .mic,
            startTime: 0,
            endTime: 1,
            text: text
        )
    }
}
