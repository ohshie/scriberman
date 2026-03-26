import SwiftUI

struct JobsView: View {
    @ObservedObject var viewModel: JobsViewModel

    var body: some View {
        ContentUnavailableView("Jobs", systemImage: "list.bullet.rectangle")
            .task {
                await viewModel.refresh()
            }
    }
}
