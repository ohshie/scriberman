import XCTest
@testable import Scriberman

final class TokenStitcherTests: XCTestCase {
    private let stitcher = TokenStitcher()

    func testNormalizeRemovesSentencepiecePrefix() {
        XCTAssertEqual(stitcher.normalizeTokenPiece("▁hello"), " hello")
    }

    func testStitchJoinsTokensAndNormalizesWhitespace() {
        XCTAssertEqual(stitcher.stitchTokens(["▁hello", "▁world"]), "hello world")
    }

    func testStitchRemovesSpaceBeforePunctuation() {
        XCTAssertEqual(stitcher.stitchTokens(["▁hello", ",", "▁world"]), "hello, world")
    }

    func testStitchHandlesContractions() {
        XCTAssertEqual(stitcher.stitchTokens(["▁it", "▁'", "s"]), "it's")
    }

    func testStitchEmptyInputReturnsEmptyString() {
        XCTAssertEqual(stitcher.stitchTokens([]), "")
    }
}
