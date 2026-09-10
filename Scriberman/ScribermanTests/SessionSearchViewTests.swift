import Foundation
import Testing
@testable import Scriberman

/// The search field and the tag filter control, asserted on the view's source: these are layout and
/// wiring rules with no runtime value to read back.
struct SessionSearchViewTests {
    private func jobsViewSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/JobsView.swift")
    }

    @Test
    func testTheSearchFieldIsBoundToTheViewModelQuery() throws {
        let source = try jobsViewSource()

        #expect(source.contains("TextField(\"Search\", text: $viewModel.searchQuery)"))
    }

    /// Present whether or not the list has anything in it: it is how the list is searched, so it
    /// cannot be the thing that disappears when the list empties.
    @Test
    func testTheSearchFieldIsOutsideTheEmptyStateBranch() throws {
        let source = try jobsViewSource()
        let barRange = try #require(source.range(of: "            searchBar"))
        let branchRange = try #require(source.range(of: "if items.isEmpty && pendingSession == nil"))

        #expect(barRange.lowerBound < branchRange.lowerBound)
    }

    @Test
    func testTagSelectionLivesInAPopoverBehindTheFilterButton() throws {
        let source = try jobsViewSource()

        #expect(source.contains(".popover(isPresented: $isShowingTagFilter"))
        #expect(source.contains("tagFilterList"))
        // The permanently visible chip row it replaces is gone.
        #expect(!source.contains("private var tagFilterChips"))
    }

    /// Without this a filtered list is indistinguishable from a short one, and the conclusion a
    /// user draws is that recordings are missing.
    @Test
    func testAnActiveFilterShowsOnTheControlWithoutOpeningIt() throws {
        let source = try jobsViewSource()
        let button = try #require(functionBody(named: "private var tagFilterButton", in: source))

        #expect(button.contains("let isFiltering = !viewModel.selectedTagIDs.isEmpty"))
        #expect(button.contains("line.3.horizontal.decrease.circle.fill"))
        #expect(button.contains("isFiltering ? Color.accentColor : Color.secondary"))
    }

    @Test
    func testRowsAreGivenTheSnippetForTheirOwnMatch() throws {
        let source = try jobsViewSource()
        let row = try #require(functionBody(named: "private func row(for item:", in: source))

        #expect(row.contains("searchSnippet: viewModel.searchMatches[item.id]?.snippet"))
    }

    /// A query that matches nothing is not an empty library, and saying "record or import audio"
    /// there would answer a question the user did not ask.
    @Test
    func testAQueryMatchingNothingGetsItsOwnEmptyState() throws {
        let source = try jobsViewSource()

        #expect(source.contains("if viewModel.activeSearchQuery != nil {"))
        #expect(source.contains("emptyState(title: \"No Results\", systemImage: \"magnifyingglass\")"))
    }

    /// Locating runs off a `.task(id:)` keyed on the query, which is what cancels an in-flight
    /// debounce when the user keeps typing.
    @Test
    func testLocatingIsKeyedOnTheQuery() throws {
        let source = try jobsViewSource()

        #expect(source.contains(".task(id: viewModel.searchQuery)"))
        #expect(source.contains("await viewModel.updateSearchMatches(for: items)"))
    }

    // MARK: - Helpers

    /// The source from a declaration up to the next one at the same indentation, so an assertion
    /// cannot drift into a neighbouring function.
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
