import SwiftData
import SwiftUI

/// The tag list shown when assigning tags to a recording.
///
/// Shared by the session list's right-click menu and the detail view's toolbar menu, so the two
/// cannot drift on which tags are offered or when they are unavailable.
struct TagAssignmentMenuContent: View {
    let session: RecordingSession
    @Environment(\.modelContext) private var modelContext

    private let service = TagService()

    var body: some View {
        // The default tag is applied and removed by rule, never chosen, so it is not listed.
        let assignable = (try? service.assignableTags(in: modelContext)) ?? []
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
    }

    private func toggle(_ tag: RecordingTag, isCarried: Bool) {
        do {
            if isCarried {
                try service.unassign(tag, from: session, in: modelContext)
            } else {
                _ = try service.assign(tag, to: session, in: modelContext)
            }
        } catch {
            // Not worth interrupting the view for; the row simply does not change.
        }
    }
}
