import XCTest

final class AppShellSidebarRegressionTests: XCTestCase {
    func testSidebarColumnRemovesDefaultSidebarToggle() throws {
        let source = try appShellSource()
        XCTAssertTrue(
            source.contains(".toolbar(removing: .sidebarToggle)"),
            "Sidebar column should remove the default sidebar toggle to avoid duplicate controls."
        )
    }

    func testSidebarToolbarUsesNativeSplitViewToggleAction() throws {
        let source = try appShellSource()
        XCTAssertTrue(
            source.contains("#selector(NSSplitViewController.toggleSidebar(_:))"),
            "Sidebar toggle should use NSSplitViewController.toggleSidebar(_:) for native animation behavior."
        )
    }

    func testSidebarToolbarUsesNavigationPlacementAndSidebarLeftIcon() throws {
        let source = try appShellSource()
        XCTAssertTrue(
            source.contains("ToolbarItem(placement: .navigation)"),
            "Sidebar toggle should live in the navigation toolbar slot."
        )
        XCTAssertTrue(
            source.contains("Image(systemName: \"sidebar.left\")"),
            "Sidebar toggle should use the standard sidebar icon."
        )
    }

    func testSidebarToggleIsNotDrivenByManualColumnVisibilityState() throws {
        let source = try appShellSource()
        XCTAssertFalse(
            source.contains("NavigationSplitView(columnVisibility:"),
            "Manual columnVisibility toggling caused non-native sidebar behavior and should not be reintroduced."
        )
    }

    func testAppShellUsesProminentDetailSplitStyleForStableDetailWidth() throws {
        let source = try appShellSource()
        XCTAssertTrue(
            source.contains(".navigationSplitViewStyle(.prominentDetail)"),
            "App shell should use prominentDetail split style to avoid detail width snap at narrow window sizes."
        )
    }

    func testSidebarColumnDeclaresWideFlexibleBounds() throws {
        let source = try appShellSource()
        XCTAssertTrue(
            source.contains(".navigationSplitViewColumnWidth(min: 380, ideal: 460)"),
            "Sidebar column should keep explicit flexible width bounds to avoid abrupt open animation jumps at narrow window widths."
        )
    }

    func testDetailColumnDeclaresMinimumAndIdealWidths() throws {
        let source = try appShellSource()
        XCTAssertTrue(
            source.contains(".navigationSplitViewColumnWidth(min: 560, ideal: 860)"),
            "Detail column should keep explicit minimum and ideal widths to prevent snap-to-final-width behavior during sidebar open."
        )
    }

    func testAppShellDoesNotClampGlobalMinimumWidth() throws {
        let source = try appShellSource()
        XCTAssertFalse(
            source.contains(".frame(minWidth:"),
            "Global minimum width clamp should remain removed so split view can negotiate widths smoothly."
        )
    }

    func testWorkspaceSelectionSheetDoesNotEnforceMinimumWidth() throws {
        let source = try appShellSource()
        XCTAssertFalse(
            source.contains(".frame(minWidth: 520)"),
            "Workspace selection sheet should avoid a fixed minimum width clamp."
        )
    }

    func testJobsViewDoesNotRenderInlineHideSidebarRow() throws {
        let source = try jobsViewSource()
        XCTAssertFalse(
            source.contains("Hide Sidebar"),
            "Hide-sidebar control must not render as an inline list row."
        )
    }

    func testJobsToolbarKeepsNewSessionPrimaryAction() throws {
        let source = try appShellSource()
        XCTAssertTrue(
            source.contains("ToolbarItem(placement: .primaryAction)"),
            "New Session action should remain in primary toolbar action placement."
        )
        XCTAssertTrue(
            source.contains("Label(\"New Session\", systemImage: \"plus\")"),
            "New Session action should keep plus icon labeling."
        )
    }

    private func appShellSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/AppShellView.swift")
    }

    private func jobsViewSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/JobsView.swift")
    }

    private func readSourceFile(relativePathFromTests: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fileURL = testsDirectory.appendingPathComponent(relativePathFromTests)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
