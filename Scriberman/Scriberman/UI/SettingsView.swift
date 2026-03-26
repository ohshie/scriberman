import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ContentUnavailableView("Settings", systemImage: "gearshape")
            .task {
                await viewModel.refresh()
            }
    }
}
