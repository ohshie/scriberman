import SwiftUI

struct SpeakerManagementView: View {
    let store: SpeakerEmbeddingStore
    @State private var profiles: [SpeakerProfile] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if profiles.isEmpty {
                Text("No speaker profiles saved yet.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading) {
                            Text(profile.name)
                                .font(.headline)
                            Text("Last seen: \(profile.lastSeen.formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteProfiles)
                }
            }
        }
        .task {
            await loadProfiles()
        }
    }

    private func loadProfiles() async {
        do {
            profiles = try await store.fetchAll()
        } catch {
            print("Failed to load speaker profiles: \(error)")
        }
        isLoading = false
    }

    private func deleteProfiles(at offsets: IndexSet) {
        let toDelete = offsets.map { profiles[$0] }
        Task {
            for profile in toDelete {
                try? await store.delete(profile)
            }
            await loadProfiles()
        }
    }
}
