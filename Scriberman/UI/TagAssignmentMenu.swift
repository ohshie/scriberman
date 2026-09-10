import OSLog
import SwiftData
import SwiftUI

/// The tag list shown when assigning tags to a recording.
///
/// Shared by the session list's right-click menu and the detail view's toolbar menu, so the two
/// cannot drift on which tags are offered or when they are unavailable.
struct TagAssignmentMenuContent: View {
    let session: RecordingSession
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @Environment(AppState.self) private var appState

    private let service = TagService()
    private let logger = Logger(subsystem: "Scriberman", category: "TagAssignmentMenu")

    var body: some View {
        // The default tag is applied and removed by rule, never chosen, so it is not listed.
        let assignable = assignableTags
        let carried = Set(session.tags.map(\.id))
        let realCount = session.tags.filter { !$0.isDefault }.count

        ForEach(assignable) { tag in
            let isCarried = carried.contains(tag.id)
            Button {
                toggle(tag, isCarried: isCarried)
            } label: {
                if isCarried {
                    Label(tag.name, systemImage: "checkmark")
                } else {
                    Text(tag.name)
                }
            }
            // Shown but unavailable at three, so the reason is visible rather than the tag silently
            // missing from the menu.
            .disabled(!isCarried && realCount >= TagService.maximumTagsPerRecording)
        }

        // Always present, so the menu is never empty. Without it a recording carrying only the
        // default tag produced no items at all, and an empty menu is indistinguishable from a
        // broken one. Tags are created in Settings, so this goes there rather than creating one
        // unnamed on the spot.
        if !assignable.isEmpty {
            Divider()
        }
        Button("Add new tag") {
            // Naming the destination, not just the window: tags have their own tab, and landing on
            // whichever tab was last open would send the user hunting for what they asked for.
            appState.requestedSettingsTab = .tags
            openSettings()
        }
    }

    /// Falls back to an empty list so the menu degrades to showing nothing rather than failing,
    /// but the reason is logged rather than lost.
    private var assignableTags: [RecordingTag] {
        do {
            return try service.assignableTags(in: modelContext)
        } catch {
            logger.error("Reading assignable tags failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func toggle(_ tag: RecordingTag, isCarried: Bool) {
        do {
            if isCarried {
                try service.unassign(tag, from: session, in: modelContext)
            } else {
                _ = try service.assign(tag, to: session, in: modelContext)
            }
        } catch {
            logger.error("Changing a recording's tags failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
