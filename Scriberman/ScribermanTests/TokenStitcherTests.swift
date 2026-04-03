import Testing
@testable import Scriberman

struct TokenStitcherTests {
    private let stitcher = TokenStitcher()

    @Test
    func normalizeRemovesSentencepiecePrefix() {
        #expect(stitcher.normalizeTokenPiece("▁hello") == " hello")
    }

    @Test
    func stitchJoinsTokensAndNormalizesWhitespace() {
        #expect(stitcher.stitchTokens(["▁hello", "▁world"]) == "hello world")
    }

    @Test
    func stitchRemovesSpaceBeforePunctuation() {
        #expect(stitcher.stitchTokens(["▁hello", ",", "▁world"]) == "hello, world")
    }

    @Test
    func stitchHandlesContractions() {
        #expect(stitcher.stitchTokens(["▁it", "▁'", "s"]) == "it's")
    }

    @Test
    func stitchEmptyInputReturnsEmptyString() {
        #expect(stitcher.stitchTokens([]) == "")
    }
}
