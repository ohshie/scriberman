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
        .confirmationDialog(
            "Restore Original?",
            isPresented: $viewModel.showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                Task {
                    await viewModel.restore()
                    if viewModel.error == nil {
                        onDismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any retranscription done on the trimmed version will be lost.")
        }
    }
}
