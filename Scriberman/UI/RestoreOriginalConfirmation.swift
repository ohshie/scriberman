import SwiftUI

extension View {
    /// The confirmation shown before restoring a splice group.
    func restoreOriginalConfirmation(isPresented: Binding<Bool>, onRestore: @escaping () -> Void) -> some View {
        confirmationDialog(
            "Restore Original?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive, action: onRestore)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This session becomes the full recording again.")
        }
    }
}
