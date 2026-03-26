import SwiftUI

struct StudioView: View {
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        ContentUnavailableView("Studio", systemImage: "waveform")
            .task {
                await viewModel.refresh()
            }
    }
}
