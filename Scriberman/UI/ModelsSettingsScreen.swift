import SwiftUI

struct ModelsSettingsScreen: View {
    var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Models") {
                ModelsSettingsView(viewModel: viewModel)
            }
        }
        .navigationTitle("Models")
        .task {
            await viewModel.refresh()
        }
    }
}
