import AppKit
import SwiftUI

struct WorkspaceOnboardingStep: View {
    @Environment(AppState.self) private var appState
    var onAdvance: () -> Void

    @State private var isSelectingFolder = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Image(systemName: "folder.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Choose a Working Folder")
                .font(.title2.weight(.semibold))

            Text("Scriberman stores models and session data in your workspace. Recommended location: ~/Documents/Scriberman.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)

            Button {
                Task {
                    await pickWorkspace()
                }
            } label: {
                if isSelectingFolder {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Text("Choose Folder")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSelectingFolder)

            if let workspace {
                Text(workspace.rootURL.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            if let errorMessage = appState.workspaceErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspace: Workspace? {
        appState.workspace
    }

    private func pickWorkspace() async {
        guard !isSelectingFolder else {
            return
        }

        isSelectingFolder = true
        defer { isSelectingFolder = false }

        guard let url = await WorkspacePicker.chooseWorkspaceFolder() else {
            return
        }

        await appState.selectWorkspace(url: url)
        if appState.workspace != nil {
            onAdvance()
        }
    }
}
