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
