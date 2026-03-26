import SwiftUI

struct ModelsSettingsScreen: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            ModelsSettingsView(viewModel: viewModel)
        }
        .navigationTitle("Models")
        .task {
            await viewModel.refresh()
        }
    }
}
