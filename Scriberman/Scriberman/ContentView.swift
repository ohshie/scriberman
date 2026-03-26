import SwiftUI

struct ContentView: View {
    var body: some View {
        AppShellView()
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
