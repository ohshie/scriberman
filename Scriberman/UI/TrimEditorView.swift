import SwiftUI

struct TrimEditorView: View {
    @State var viewModel: TrimEditorViewModel
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Drag to set the end of the recording.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Slider(
                    value: $viewModel.trimPosition,
                    in: 0...max(viewModel.session.duration, 1)
                )
                .disabled(viewModel.isApplying)

                Text(viewModel.keepRangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let error = viewModel.error {
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                if viewModel.session.isTrimmed {
                    Button("Restore Original…", role: .destructive) {
                        viewModel.showRestoreConfirmation = true
                    }
                    .disabled(viewModel.isApplying)
                }

                Spacer()

                Button("Preview") {
                    viewModel.preview()
                }
                .disabled(viewModel.isApplying)

                Button("Apply Trim") {
                    Task {
                        await viewModel.applyTrim()
                        if viewModel.error == nil {
                            onDismiss()
                        }
                    }
                }
                .disabled(viewModel.isAtFullDuration || viewModel.isApplying)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .navigationTitle("Trim Recording")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDismiss)
                    .disabled(viewModel.isApplying)
            }
        }
        .overlay {
            if viewModel.isApplying {
                ProgressView()
            }
        }
        .restoreOriginalConfirmation(isPresented: $viewModel.showRestoreConfirmation) {
            Task {
                await viewModel.restore()
                if viewModel.error == nil {
                    onDismiss()
                }
            }
        }
    }
}

extension View {
    /// The confirmation shown before a trimmed recording is restored, shared by the trim sheet and
    /// the detail toolbar.
    func restoreOriginalConfirmation(isPresented: Binding<Bool>, onRestore: @escaping () -> Void) -> some View {
        confirmationDialog(
            "Restore Original?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive, action: onRestore)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any retranscription done on the trimmed version will be lost.")
        }
    }
}
