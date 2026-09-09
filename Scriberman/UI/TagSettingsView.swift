import AppKit
import OSLog
import SwiftData
import SwiftUI

/// Tag management: create, rename, recolour, delete.
///
/// Every tag in the application is created here. The assignment menu offers existing tags only, so
/// this is the one place a tag comes into being.
struct TagSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingTag.createdAt) private var tags: [RecordingTag]

    @State private var pendingDeletion: RecordingTag?
    /// Which name field holds focus. Clicking away clears it; the name is already persisted on
    /// every keystroke, so losing focus commits nothing new — it just stops the field looking
    /// half-edited.
    @FocusState private var focusedTagID: UUID?

    private let service = TagService()
    private let logger = Logger(subsystem: "Scriberman", category: "TagSettingsView")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tags) { tag in
                row(for: tag)
            }

            Button("Add new tag") {
                addTag()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Clicking anywhere that is not a name field drops focus.
        .onTapGesture {
            focusedTagID = nil
        }
        .confirmationDialog(
            pendingDeletion.map { "Are you sure you want to remove \($0.name)?" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let pendingDeletion {
                    delete(pendingDeletion)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        }
    }

    @ViewBuilder
    private func row(for tag: RecordingTag) -> some View {
        HStack(spacing: 8) {
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(tagHex: tag.colorHex) },
                    set: { recolor(tag, to: $0) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()

            TextField(
                "Name",
                text: Binding(
                    get: { tag.name },
                    set: { rename(tag, to: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .focused($focusedTagID, equals: tag.id)
            .onSubmit { focusedTagID = nil }

            // The default tag is the lower bound on a recording's tag count, so it has no delete
            // action — removing it would leave the bound with no rule to fall back on.
            if !tag.isDefault {
                Button(role: .destructive) {
                    pendingDeletion = tag
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove")
            }
        }
    }

    private func addTag() {
        // Created with a placeholder name and a random colour, then renamed in place. An empty
        // name is refused on the way back in, so the tag cannot be left nameless.
        do {
            try service.createTag(name: "Name", in: modelContext)
        } catch {
            logger.error("Creating a tag failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rename(_ tag: RecordingTag, to name: String) {
        // A momentarily empty field is normal while typing; the service refuses to persist it and
        // the previous name stands. Only that case is expected, so anything else is logged.
        do {
            try service.rename(tag, to: name, in: modelContext)
        } catch TagError.emptyName {
            // Expected while typing.
        } catch {
            logger.error("Renaming a tag failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recolor(_ tag: RecordingTag, to color: Color) {
        guard let hex = color.tagHexValue else { return }
        do {
            try service.recolor(tag, to: hex, in: modelContext)
        } catch {
            logger.error("Recolouring a tag failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func delete(_ tag: RecordingTag) {
        do {
            try service.delete(tag, in: modelContext)
        } catch {
            logger.error("Deleting a tag failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Color {
    /// `RRGGBB` for this colour, or `nil` when it cannot be resolved in sRGB.
    var tagHexValue: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }
}
