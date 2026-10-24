import Testing
import Foundation

@Suite("AppShell Sidebar Regression Tests")
struct AppShellSidebarRegressionTests {
    
    @Test("Sidebar toggle is the system's own control", .tags(.sourceLint))
    func sidebarToggleIsTheSystemControl() throws {
        let source = try appShellSource()
        #expect(!source.contains(".toolbar(removing: .sidebarToggle)"))
        #expect(!source.contains("NSSplitViewController.toggleSidebar"))
    }

    @Test("Window title is set on the split view and kept out of the toolbar", .tags(.sourceLint))
    func windowTitleIsSetAndKeptOutOfTheToolbar() throws {
        let source = try appShellSource()
        #expect(source.contains(".navigationTitle(Self.windowTitle(for: selectedSession))"))
        #expect(source.contains(".toolbar(removing: .title)"))

        // A title set inside the detail column takes precedence over the split view's and would
        // blank the window title.
        let detailView = try transcriptDetailViewSource()
        #expect(!detailView.contains(".navigationTitle("))
    }

    @Test("Sidebar toggle is not driven by manual column visibility state", .tags(.sourceLint))
    func sidebarToggleIsNotDrivenByManualColumnVisibilityState() throws {
        let source = try appShellSource()
        #expect(
            !source.contains("NavigationSplitView(columnVisibility:"),
            "Manual columnVisibility toggling caused non-native sidebar behavior and should not be reintroduced."
        )
    }

    @Test("App shell uses prominent detail split style for stable detail width", .tags(.sourceLint))
    func appShellUsesProminentDetailSplitStyleForStableDetailWidth() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".navigationSplitViewStyle(.prominentDetail)"),
            "App shell should use prominentDetail split style to avoid detail width snap at narrow window sizes."
        )
    }

    @Test("Sidebar column declares wide flexible bounds", .tags(.sourceLint))
    func sidebarColumnDeclaresWideFlexibleBounds() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".navigationSplitViewColumnWidth(min: 380, ideal: 460)"),
            "Sidebar column should keep explicit flexible width bounds to avoid abrupt open animation jumps at narrow window widths."
        )
    }

    @Test("Detail column declares minimum and ideal widths", .tags(.sourceLint))
    func detailColumnDeclaresMinimumAndIdealWidths() throws {
        let source = try appShellSource()
        #expect(
            source.contains(".navigationSplitViewColumnWidth(min: 560, ideal: 860)"),
            "Detail column should keep explicit minimum and ideal widths to prevent snap-to-final-width behavior during sidebar open."
        )
    }

    @Test("App shell does not clamp global minimum width", .tags(.sourceLint))
    func appShellDoesNotClampGlobalMinimumWidth() throws {
        let source = try appShellSource()
        #expect(
            !source.contains(".frame(minWidth:"),
            "Global minimum width clamp should remain removed so split view can negotiate widths smoothly."
        )
    }

    @Test("Workspace selection sheet does not enforce minimum width", .tags(.sourceLint))
    func workspaceSelectionSheetDoesNotEnforceMinimumWidth() throws {
        let source = try appShellSource()
        #expect(
            !source.contains(".frame(minWidth: 520)"),
            "Workspace selection sheet should avoid a fixed minimum width clamp."
        )
    }

    @Test("Jobs view does not render inline hide sidebar row", .tags(.sourceLint))
    func jobsViewDoesNotRenderInlineHideSidebarRow() throws {
        let source = try jobsViewSource()
        #expect(
            !source.contains("Hide Sidebar"),
            "Hide-sidebar control must not render as an inline list row."
        )
    }

    @Test("Jobs toolbar keeps new session primary action", .tags(.sourceLint))
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

    @Test("Detail toolbar Copy uses the shared transcript copy helper", .tags(.sourceLint))
    func detailToolbarCopyUsesSharedTranscriptCopyHelper() throws {
        let appShell = try appShellSource()
        let wiring = "onCopy: {\n                copyTranscript(for: session)\n            },"
        #expect(
            appShell.components(separatedBy: wiring).count - 1 == 1,
            "The one TranscriptDetailView call site, used for recordings and imports, should wire Copy to copyTranscript(for: session)."
        )

        let detailView = try transcriptDetailViewSource()
        #expect(
            detailView.contains("Button {\n                    onCopy()\n                } label: {\n                    Label(\"Copy\", systemImage: \"doc.on.doc\")"),
            "The detail toolbar Copy button should call the parent's copy action."
        )
        #expect(
            !detailView.contains("setString(viewModel.finalTranscriptText"),
            "TranscriptDetailView should not copy the unattributed transcript text."
        )
    }

    @Test("Recording sessions route to active recording detail view while status is recording", .tags(.sourceLint))
    func recordingSessionsRouteToActiveRecordingDetailView() throws {
        let source = try appShellSource()
        #expect(source.contains("if session.status == .recording {"))
        #expect(source.contains("ActiveRecordingDetailView("))
        #expect(source.contains("viewModel: appState.newSessionViewModel"))
        #expect(source.contains("modelContext: modelContext"))
    }

    @Test("App activation refreshes permissions via AppState", .tags(.sourceLint))
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

    private func transcriptDetailViewSource() throws -> String {
        try readSourceFile(relativePathFromTests: "../UI/TranscriptDetailView.swift")
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
