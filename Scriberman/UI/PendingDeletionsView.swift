import SwiftUI

/// The sessions waiting to be removed for good, in the detail area. Each row restores its session
/// or, after the delete confirmation, removes it now.
struct PendingDeletionsView: View {
    let viewModel: PendingDeletionsViewModel
    let onRevert: (PendingDeletionsViewModel.Row) -> Void
    /// Called once the user has confirmed.
    let onRemoveNow: (PendingDeletionsViewModel.Row) -> Void

    @State private var rowPendingRemoval: PendingDeletionsViewModel.Row?

    var body: some View {
        // Redrawn every minute, so the time until removal stays current.
        TimelineView(.everyMinute) { _ in
            List {
                Text("Pending deletions")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.bottom, 8)
                    .listRowSeparator(.hidden)

                ForEach(viewModel.rows) { row in
                    rowView(for: row)
                }
            }
            .listStyle(.inset)
        }
        .alert(
            "Delete “\(rowPendingRemoval?.title ?? "")”?",
            isPresented: Binding(
                get: { rowPendingRemoval != nil },
                set: { if !$0 { rowPendingRemoval = nil } }
            ),
            presenting: rowPendingRemoval
        ) { row in
            Button("Delete", role: .destructive) {
                onRemoveNow(row)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This permanently deletes the session and its files.")
        }
    }

    private func rowView(for row: PendingDeletionsViewModel.Row) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.title)
                    .font(.headline)
                    .lineLimit(1)

                // Date and duration as the session list shows them.
                HStack(spacing: 6) {
                    Text(JobsViewModel.relativeTimestampText(for: row.createdAt))
                    Text("•")
                    Text(TimeFormatter.displayFormat(seconds: Float(row.duration)))
                    Spacer(minLength: 8)
                    Text(viewModel.countdownText(for: row))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            iconButton("Restore session", systemImage: "arrow.uturn.backward") {
                onRevert(row)
            }
            iconButton("Delete permanently", systemImage: "trash") {
                rowPendingRemoval = row
            }
        }
        .padding(.vertical, 4)
    }

    private func iconButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
