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
    func testTheSearchFieldIsTheSystemsOwn() throws {
        let source = try jobsViewSource()

        #expect(source.contains("NativeSearchField("))
        #expect(source.contains("text: $viewModel.searchQuery"))
        #expect(source.contains("prompt: \"Search\""))
        // The capsule we drew, and the height we had to pin to stop it laying out on two lines.
        #expect(!source.contains("TextField(\"Search\""))
        #expect(!source.contains("Capsule().fill(Color.secondary.opacity(0.12))"))
    }

    @Test
    func testTheWrapperUsesAnNSSearchField() throws {
        let source = try readSourceFile(relativePathFromTests: "../UI/NativeSearchField.swift")

        #expect(source.contains("NSViewRepresentable"))
        #expect(source.contains("NSSearchField()"))
        #expect(source.contains("field.placeholderString = prompt"))
    }

    /// Escape clears the query; Escape on an already empty field hands focus back, so the key
    /// belongs to the window rather than to the control.
    @Test
    func testEscapeClearsThenReleasesFocus() throws {
        let source = try readSourceFile(relativePathFromTests: "../UI/NativeSearchField.swift")

        #expect(source.contains("#selector(NSResponder.cancelOperation(_:))"))
        #expect(source.contains("parent.onEscapeWhileEmpty()"))
        #expect(source.contains("parent.text = \"\""))
    }

    /// SwiftUI shortcuts are handled at the window level, so the transcript find bar's Escape took
    /// the key before the field's own editor saw it — Escape in the search field did nothing while
    /// a transcript was open.
    @Test
    func testEscapeIsInterceptedWhileTheFieldIsBeingEdited() throws {
        let source = try readSourceFile(relativePathFromTests: "../UI/NativeSearchField.swift")

        #expect(source.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(source.contains("event.keyCode == 53"))
        // Only while this field holds the keyboard, and torn down when it stops.
        #expect(source.contains("guard let field, field.currentEditor() != nil else { return event }"))
        #expect(source.contains("func controlTextDidEndEditing"))
        #expect(source.contains("stopWatchingForEscape()"))
        #expect(source.contains("static func dismantleNSView"))
    }

    /// One handler owns ⌘F, so what it means is decided in one place rather than by whichever of
    /// two views holds focus.
    @Test
    func testOneHandlerOwnsTheFindShortcut() throws {
        let shell = try readSourceFile(relativePathFromTests: "../UI/AppShellView.swift")
        let study = try readSourceFile(relativePathFromTests: "../UI/TranscriptStudyView.swift")

        #expect(shell.contains("if detailMode == .study {"))
        #expect(shell.contains("NotificationCenter.default.post(name: .transcriptSearchRequested"))
        #expect(shell.contains("searchFocusRequest += 1"))
        #expect(shell.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        // The study view keeps its observer and its toolbar action, but no longer claims the key.
        #expect(!study.contains(".keyboardShortcut(\"f\", modifiers: .command)"))
        #expect(study.contains("publisher(for: .transcriptSearchRequested)"))
    }

    /// Present whether or not the list has anything in it: it is how the list is searched, so it
    /// cannot be the thing that disappears when the list empties.
    @Test
    func testTheSearchFieldIsOutsideTheEmptyStateBranch() throws {
        let source = try jobsViewSource()

        // An inset applied to the whole stack, not a view inside the branch the empty state
        // replaces.
        #expect(source.contains(".safeAreaInset(edge: .top, spacing: 0) {"))
        let insetRange = try #require(source.range(of: ".safeAreaInset(edge: .top, spacing: 0) {"))
        let branchRange = try #require(source.range(of: "if items.isEmpty && pendingSession == nil"))
        #expect(insetRange.lowerBound > branchRange.lowerBound)
    }

    /// Rows scrolled up behind the field and stayed there until the list was dragged back down. As
    /// a sibling in the stack the scroll view never reserved the space; as an inset it does, and
    /// the material hides whatever passes beneath.
    @Test
    func testTheSearchRowReservesItsSpaceAndIsOpaque() throws {
        let source = try jobsViewSource()

        #expect(source.contains(".safeAreaInset(edge: .top, spacing: 0) {"))
        #expect(source.contains("searchBar\n                .background(.bar)"))
    }

    /// The filter narrows the same set the query searches, so it stays in the search row.
    @Test
    func testTheFilterStaysBesideTheField() throws {
        let source = try jobsViewSource()
        let bar = try #require(functionBody(named: "private var searchBar: some View {", in: source))

        #expect(bar.contains("NativeSearchField("))
        #expect(bar.contains("tagFilterButton"))
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

    /// The count sits outside the branch the empty state replaces, so a query matching nothing
    /// still says how much is being withheld.
    @Test
    func testTheListCountIsOutsideTheEmptyStateBranch() throws {
        let source = try jobsViewSource()
        let branch = try #require(source.range(of: "if items.isEmpty && pendingSession == nil"))
        let count = try #require(source.range(of: "            listCount"))

        #expect(count.lowerBound > branch.lowerBound)
        #expect(source.contains("JobsViewModel.listCountText(shown: items.count, total: totalSessionCount)"))
    }

    // MARK: - Motion

    /// One moment, not three. Rows and the selection fill are drawn by AppKit, so a SwiftUI
    /// animation over them animates the whole table re-rendering — a wobble on every keystroke.
    @Test
    func testOnlyTheEmptyStateSwapIsAnimated() throws {
        let source = try jobsViewSource()

        #expect(source.contains(".animation(listMotion, value: items.isEmpty)"))
        #expect(!source.contains(".animation(listMotion, value: items)"))
        #expect(!source.contains(".animation(listMotion, value: selection)"))
        #expect(source.components(separatedBy: ".animation(").count - 1 == 1)
        #expect(!source.contains("withAnimation"))
    }

    @Test
    func testMotionIsShortAndHonoursReduceMotion() throws {
        let source = try jobsViewSource()

        #expect(source.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        #expect(source.contains("reduceMotion ? nil : .easeOut(duration: 0.22)"))
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
