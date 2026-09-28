import Observation
import OSLog
import SwiftUI

/// The speaker profiles Settings shows, and whether the last delete failed.
@MainActor
@Observable
final class SpeakerProfileList {
    private(set) var profiles: [SpeakerProfileSnapshot] = []
    private(set) var isLoading = true
    /// Set when a delete fails; cleared by the next delete that succeeds.
    private(set) var deleteFailed = false

    @ObservationIgnored private let fetch: () async throws -> [SpeakerProfileSnapshot]
    @ObservationIgnored private let logger = Logger(subsystem: "Scriberman", category: "SpeakerProfileList")

    init(fetch: @escaping () async throws -> [SpeakerProfileSnapshot]) {
        self.fetch = fetch
    }

    convenience init(store: SpeakerEmbeddingStore) {
        self.init(fetch: { try await store.fetchAllSnapshots() })
    }

    func load() async {
        do {
            profiles = try await fetch()
        } catch {
            print("Failed to load speaker profiles: \(error)")
        }
        isLoading = false
    }

    /// Runs `operation`, then reloads the list from storage whether or not it succeeded.
    func delete(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            deleteFailed = false
        } catch {
            deleteFailed = true
            logger.error("Deleting speaker profiles failed: \(error.localizedDescription, privacy: .public)")
        }
        await load()
    }
}

struct SpeakerManagementView: View {
    let store: SpeakerEmbeddingStore
    @State private var list: SpeakerProfileList
    @State private var showDeleteAllConfirmation = false

    init(store: SpeakerEmbeddingStore) {
        self.store = store
        _list = State(initialValue: SpeakerProfileList(store: store))
    }

    var body: some View {
        Group {
            if list.isLoading {
                ProgressView()
            } else if list.profiles.isEmpty {
                Text("No speaker profiles saved yet.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(list.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                    .font(.headline)
                                Text("Last seen: \(profile.lastSeen.formatted())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await list.delete { try await store.deleteProfile(id: profile.id) } }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete speaker")
                        }
                    }
                }

                Button("Delete All Speaker Profiles", role: .destructive) {
                    showDeleteAllConfirmation = true
                }
            }

            if list.deleteFailed {
                Text("Couldn't delete speaker profile.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Are you sure?", isPresented: $showDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) {
                Task { await list.delete { try await store.deleteAllProfiles() } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task {
            await list.load()
        }
    }
}
