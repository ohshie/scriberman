import Foundation
import Testing
@testable import Scriberman

/// Opening a search result: the study view arrives with the query applied and the matched block
/// selected, and nothing starts playing.
@MainActor
struct TranscriptStudySearchSeedTests {
    private func blocks(_ lines: [String]) -> [TranscriptBlock] {
        lines.enumerated().map { index, line in
            TranscriptBlock(
                speaker: TranscriptSpeaker(id: "speaker-\(index)", label: "Speaker", colorHex: "#112233"),
                audioSource: .mic,
                startTime: Float(index),
                endTime: Float(index) + 1,
                text: line
            )
        }
    }

    // MARK: - Selecting the seeded match

    @Test
    func testSelectingAMatchByBlockMovesOffTheFirstMatch() {
        let blocks = blocks([
            "the migration is mentioned here first",
            "and the migration again later",
        ])
        let state = TranscriptSearchState()
        state.query = "migration"
        state.update(blocks: blocks)

        #expect(state.currentMatch?.blockID == blocks[0].id)

        state.selectFirstMatch(inBlock: blocks[1].id)

        #expect(state.currentMatch?.blockID == blocks[1].id)
        // The highlight the study view draws comes from the same selection.
        #expect(state.activeRange(in: blocks[1]) != nil)
        #expect(state.activeRange(in: blocks[0]) == nil)
    }

    @Test
    func testSelectingABlockWithNoMatchLeavesTheSelectionAlone() {
        let blocks = blocks([
            "the migration is mentioned here",
            "nothing relevant in this one",
        ])
        let state = TranscriptSearchState()
        state.query = "migration"
        state.update(blocks: blocks)

        state.selectFirstMatch(inBlock: blocks[1].id)

        #expect(state.currentMatch?.blockID == blocks[0].id)
    }

    @Test
    func testTwoSeedsForTheSameMatchAreDifferentValues() {
        let blockID = UUID()
        let first = TranscriptStudySearchSeed(query: "migration", blockID: blockID)
        let second = TranscriptStudySearchSeed(query: "migration", blockID: blockID)

        // Clicking the same result again has to move the view again, so the seed must not compare
        // equal to the one already applied.
        #expect(first != second)
    }

    // MARK: - The view's wiring

    @Test
    func testTheSeedIsAppliedFromATaskKeyedOnIt() throws {
        let source = try studyViewSource()

        #expect(source.contains(".task(id: searchSeed)"))
        #expect(source.contains("applySearchSeed()"))
    }

    @Test
    func testApplyingASeedSelectsTheMatchAndScrollsToIt() throws {
        let body = try #require(functionBody(named: "private func applySearchSeed()", in: try studyViewSource()))

        #expect(body.contains("searchState.query = searchSeed.query"))
        #expect(body.contains("searchState.selectFirstMatch(inBlock: blockID)"))
        #expect(body.contains("scrollTargetID = searchState.currentMatch?.blockID"))
        #expect(body.contains("isSearchVisible = true"))
    }

    /// Opening a session that was not reached by search leaves the view exactly as it was: empty
    /// find bar, no match, nothing hidden.
    @Test
    func testNoSeedLeavesTheViewUnchanged() throws {
        let body = try #require(functionBody(named: "private func applySearchSeed()", in: try studyViewSource()))

        #expect(body.contains("guard let searchSeed, !searchSeed.query.isEmpty else { return }"))
    }

    /// Locating text and listening to it are separate intentions.
    @Test
    func testApplyingASeedStartsNoPlayback() throws {
        let body = try #require(functionBody(named: "private func applySearchSeed()", in: try studyViewSource()))

        #expect(!body.contains("audioPlayerViewModel"))
        #expect(!body.contains(".play()"))
    }

    @Test
    func testOpeningAResultStartsNoPlayback() throws {
        let body = try #require(functionBody(named: "private func openSearchResult(", in: try appShellSource()))

        #expect(!body.contains(".play()"))
    }

    /// A seeded search is dismissed by the same path as one the user opened, so Escape behaves the
    /// same either way.
    @Test
    func testASeededSearchIsDismissedLikeAnyOther() throws {
        let source = try studyViewSource()
        let dismiss = try #require(functionBody(named: "private func dismissSearch()", in: source))

        #expect(dismiss.contains("searchState.query = \"\""))
        #expect(dismiss.contains("isSearchVisible = false"))
        // The find bar's own Escape shortcut calls that one dismissal.
        #expect(source.contains("TranscriptFindBar(searchState: searchState) {"))
    }

    /// Clicking a result whose session is already selected changes no binding, so the row reports
    /// the click itself.
    @Test
    func testAClickOnAResultIsReportedEvenWithoutASelectionChange() throws {
        let source = try readSourceFile(relativePathFromTests: "../UI/JobsView.swift")

        #expect(source.contains(".simultaneousGesture(TapGesture().onEnded {"))
        #expect(source.contains("onOpenSearchResult(item)"))
        #expect(source.contains("guard viewModel.activeSearchQuery != nil else { return }"))
    }

    /// The selection change handler resets the detail view. Without this guard it would undo the
    /// navigation that caused the change.
    @Test
    func testSelectingAResultIsNotResetByTheSelectionHandler() throws {
        let source = try appShellSource()

        #expect(source.contains("let isOpeningSearchResult = newValue != nil && newValue?.id == studySearchSeedItemID"))
        #expect(source.contains("guard !isOpeningSearchResult else { return }"))
    }

    // MARK: - Helpers

    private func studyViewSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/TranscriptStudyView.swift")
    }

    private func appShellSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/AppShellView.swift")
    }

    private func functionBody(named declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: testsDirectory.appendingPathComponent(relativePathFromTests),
            encoding: .utf8
        )
    }
}
