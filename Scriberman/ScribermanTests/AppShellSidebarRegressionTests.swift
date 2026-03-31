import Testing
import Foundation

@Suite("AppShell Sidebar Regression Tests")
struct AppShellSidebarRegressionTests {
    
    @Test("Sidebar column removes default sidebar toggle")
    func sidebarColumnRemovesDefaultSidebarToggle() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".toolbar(removing: .sidebarToggle)"),
            "Sidebar column should remove the default sidebar toggle to avoid duplicate controls."
        )
    }

    @Test("Sidebar toolbar uses native split view toggle action")
    func sidebarToolbarUsesNativeSplitViewToggleAction() throws {
        let source = try appShellSource()
        #expect(
            source.contains("#selector(NSSplitViewController.toggleSidebar(_:))"),
            "Sidebar toggle should use NSSplitViewController.toggleSidebar(_:) for native animation behavior."
        )
    }

    @Test("Sidebar toolbar uses navigation placement and sidebar left icon")
    func sidebarToolbarUsesNavigationPlacementAndSidebarLeftIcon() throws {
        let source = try appShellSource()
        #expect(
            source.contains("ToolbarItem(placement: .navigation)"),
            "Sidebar toggle should live in the navigation toolbar slot."
        )
        #expect(
            source.contains("Image(systemName: \"sidebar.left\")"),
            "Sidebar toggle should use the standard sidebar icon."
        )
    }

    @Test("Sidebar toggle is not driven by manual column visibility state")
    func sidebarToggleIsNotDrivenByManualColumnVisibilityState() throws {
        let source = try appShellSource()
        #expect(
            !source.contains("NavigationSplitView(columnVisibility:"),
            "Manual columnVisibility toggling caused non-native sidebar behavior and should not be reintroduced."
        )
    }

    @Test("App shell uses prominent detail split style for stable detail width")
    func appShellUsesProminentDetailSplitStyleForStableDetailWidth() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".navigationSplitViewStyle(.prominentDetail)"),
            "App shell should use prominentDetail split style to avoid detail width snap at narrow window sizes."
        )
    }

    @Test("Sidebar column declares wide flexible bounds")
    func sidebarColumnDeclaresWideFlexibleBounds() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".navigationSplitViewColumnWidth(min: 380, ideal: 460)"),
            "Sidebar column should keep explicit flexible width bounds to avoid abrupt open animation jumps at narrow window widths."
        )
    }

    @Test("Detail column declares minimum and ideal widths")
    func detailColumnDeclaresMinimumAndIdealWidths() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".navigationSplitViewColumnWidth(min: 560, ideal: 860)"),
            "Detail column should keep explicit minimum and ideal widths to prevent snap-to-final-width behavior during sidebar open."
        )
    }

    @Test("App shell does not clamp global minimum width")
    func appShellDoesNotClampGlobalMinimumWidth() throws {
        let source = try appShellSource()
        #expect(
            !source.contains(".frame(minWidth:"),
            "Global minimum width clamp should remain removed so split view can negotiate widths smoothly."
        )
    }

    @Test("Workspace selection sheet does not enforce minimum width")
    func workspaceSelectionSheetDoesNotEnforceMinimumWidth() throws {
        let source = try appShellSource()
        #expect(
            !source.contains(".frame(minWidth: 520)"),
            "Workspace selection sheet should avoid a fixed minimum width clamp."
        )
    }

    @Test("Jobs view does not render inline hide sidebar row")
    func jobsViewDoesNotRenderInlineHideSidebarRow() throws {
        let source = try jobsViewSource()
        #expect(
            !source.contains("Hide Sidebar"),
            "Hide-sidebar control must not render as an inline list row."
        )
    }

    @Test("Jobs toolbar keeps new session primary action")
    func jobsToolbarKeepsNewSessionPrimaryAction() throws {
        let source = try appShellSource()
        #expect(
            source.contains("ToolbarItem(placement: .primaryAction)"),
            "New Session action should remain in primary toolbar action placement."
        )
        #expect(
            source.contains("Label(\"New Session\", systemImage: \"plus\")"),
            "New Session action should keep plus icon labeling."
        )
    }

    @Test("App shell defines detail mode and defaults to standard")
    func appShellDefinesDetailModeAndDefaultsToStandard() throws {
        let source = try appShellSource()
        #expect(
            source.contains("private enum DetailMode"),
            "App shell should define an explicit detail mode for in-place transcript navigation."
        )
        #expect(
            source.contains("@State private var detailMode: DetailMode = .standard"),
            "App shell should default detail mode to standard."
        )
    }

    @Test("Preview tap switches detail mode to study")
    func previewTapSwitchesDetailModeToStudy() throws {
        let source = try appShellSource()
        #expect(
            source.contains("onOpenStudy: {\n                        detailMode = .study"),
            "Opening study mode should be triggered from transcript preview tap action."
        )
    }

    @Test("App shell resets detail mode when selection changes")
    func appShellResetsDetailModeWhenSelectionChanges() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".onChange(of: selectedSession)"),
            "App shell should observe selected session changes."
        )
        #expect(
            source.contains("detailMode = .standard"),
            "Selecting a different session should reset the detail mode to standard."
        )
    }

    @Test("Study mode toolbar provides back button and study actions")
    func studyModeToolbarProvidesBackButtonAndStudyActions() throws {
        let source = try appShellSource()
        #expect(
            source.contains("Image(systemName: \"chevron.left\")"),
            "Study mode should provide icon-only chevron back navigation."
        )
        #expect(
            source.contains("TranscriptStudyView.toolbarActions("),
            "Study mode toolbar should include transcript copy and export actions."
        )
        #expect(
            source.contains("copyTranscript(for: session)"),
            "Study mode toolbar should wire copy action to transcript copy helper."
        )
        #expect(
            source.contains("exportTranscript(for: session)"),
            "Study mode toolbar should wire export action to transcript export helper."
        )
    }

    @Test("Study mode renders TranscriptStudyView in place")
    func studyModeRendersTranscriptStudyViewInPlace() throws {
        let source = try appShellSource()
        #expect(
            source.contains("if detailMode == .study, let transcript = displayedTranscript(for: session) {\n                TranscriptStudyView(\n                    session: session,\n                    transcript: transcript,\n                    store: appState.backgroundServices.speakerEmbeddingStore\n                )"),
            "App shell should render TranscriptStudyView in the detail column when study mode is active."
        )
    }

    @Test("App activation refreshes permissions via AppState")
    func appActivationRefreshesPermissionsViaAppState() throws {
        let source = try appShellSource()
        #expect(
            source.contains("await appState.refreshPermissionsOnActivation()"),
            "Scene activation should trigger strict permission refresh through AppState."
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
