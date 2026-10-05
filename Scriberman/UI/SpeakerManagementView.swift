import Observation
import OSLog
import SwiftData
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
    @ObservationIgnored private let store: SpeakerEmbeddingStore?
    @ObservationIgnored private let logger = Logger(subsystem: "Scriberman", category: "SpeakerProfileList")

    /// What committing a new name for a profile led to.
    enum RenameOutcome: Equatable {
        /// The name was empty or the profile's own; nothing changed.
        case unchanged
        case renamed
        /// Another profile has the name; renaming needs the user to confirm a merge into it.
        case needsMerge(targetID: UUID)
    }

    init(fetch: @escaping () async throws -> [SpeakerProfileSnapshot], store: SpeakerEmbeddingStore? = nil) {
        self.fetch = fetch
        self.store = store
    }

    convenience init(store: SpeakerEmbeddingStore) {
        self.init(fetch: { try await store.fetchAllSnapshots() }, store: store)
    }

    /// Renames profile `id` to `name` unless another profile has that name, case-insensitively, in
    /// which case it changes nothing and asks for a merge.
    func rename(_ id: UUID, to name: String) async -> RenameOutcome {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty,
              let profile = profiles.first(where: { $0.id == id }), profile.name != trimmed
        else { return .unchanged }
        if let other = profiles.first(where: { $0.id != id && $0.name.lowercased() == trimmed.lowercased() }) {
            return .needsMerge(targetID: other.id)
        }
        do {
            try await store.renameProfile(id: id, name: trimmed)
        } catch {
            logger.error("Renaming a speaker profile failed: \(error.localizedDescription, privacy: .public)")
        }
        await load()
        return .renamed
    }

    /// Merges profile `id` into `targetID`, then reloads.
    func merge(_ id: UUID, into targetID: UUID) async {
        do {
            try await store?.mergeProfile(id: id, into: targetID)
        } catch {
            logger.error("Merging speaker profiles failed: \(error.localizedDescription, privacy: .public)")
        }
        await load()
    }

    /// The voiceprints of profile `id`, newest first.
    func voiceprints(of id: UUID) async -> [SpeakerVoiceprintSnapshot] {
        do {
            return try await store?.voiceprintSnapshots(profileID: id) ?? []
        } catch {
            logger.error("Loading voiceprints failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Removes one voiceprint, then reloads.
    func removeVoiceprint(_ id: UUID) async {
        do {
            try await store?.removeVoiceprint(id: id)
        } catch {
            logger.error("Removing a voiceprint failed: \(error.localizedDescription, privacy: .public)")
        }
        await load()
    }

    /// The caption suffix for a voiceprint count.
    static func voiceprintCountText(_ count: Int) -> String {
        count == 1 ? "1 voiceprint" : "\(count) voiceprints"
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
    @State private var renamingProfileID: UUID?
    @State private var pendingMerge: PendingMerge?

    private struct PendingMerge {
        let id: UUID
        let targetID: UUID
    }

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
                        SpeakerProfileRow(
                            profile: profile,
                            list: list,
                            isRenaming: renamingProfileID == profile.id,
                            onBeginRename: { renamingProfileID = profile.id },
                            onEndRename: {
                                if renamingProfileID == profile.id {
                                    renamingProfileID = nil
                                }
                            },
                            onRename: { name in
                                Task {
                                    if case .needsMerge(let targetID) = await list.rename(profile.id, to: name) {
                                        pendingMerge = PendingMerge(id: profile.id, targetID: targetID)
                                    }
                                }
                            },
                            onDelete: {
                                Task { await list.delete { try await store.deleteProfile(id: profile.id) } }
                            }
                        )
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
        .alert(
            "Merge profiles?",
            isPresented: Binding(get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            presenting: pendingMerge
        ) { merge in
            Button("Cancel", role: .cancel) {}
            Button("merge") {
                Task { await list.merge(merge.id, into: merge.targetID) }
            }
            .keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("Both profiles become one.")
        }
        .task {
            await list.load()
        }
    }
}

/// One profile in Settings: its name or rename field, caption, actions, and its voiceprints.
private struct SpeakerProfileRow: View {
    let profile: SpeakerProfileSnapshot
    let list: SpeakerProfileList
    let isRenaming: Bool
    let onBeginRename: () -> Void
    let onEndRename: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var isExpanded = false
    @State private var voiceprints: [SpeakerVoiceprintSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading) {
                    if isRenaming {
                        SpeakerNameField(
                            name: profile.name,
                            profiles: [],
                            showsSuggestions: false,
                            onCommit: { name in
                                onRename(name)
                                onEndRename()
                            },
                            onCancel: onEndRename
                        )
                    } else {
                        Text(profile.name)
                            .font(.headline)
                    }
                    Text("Last seen: \(profile.lastSeen.formatted()) · \(SpeakerProfileList.voiceprintCountText(profile.sampleCount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onBeginRename()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Rename speaker")
                .accessibilityLabel("Rename speaker")
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete speaker")
            }

            DisclosureGroup("Voiceprints", isExpanded: $isExpanded) {
                ForEach(voiceprints) { voiceprint in
                    HStack {
                        voiceprintSourceText(voiceprint)
                            .font(.caption)
                        Spacer()
                        Button {
                            Task {
                                await list.removeVoiceprint(voiceprint.id)
                                await loadVoiceprints()
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Forget voiceprint")
                        .accessibilityLabel("Forget voiceprint")
                    }
                }
            }
            .font(.caption)
            // Voiceprints load only when expanded, and again when the profile's count changes.
            .task(id: isExpanded ? profile.sampleCount : nil) {
                if isExpanded {
                    await loadVoiceprints()
                }
            }
        }
    }

    private func loadVoiceprints() async {
        voiceprints = await list.voiceprints(of: profile.id)
    }

    @ViewBuilder
    private func voiceprintSourceText(_ voiceprint: SpeakerVoiceprintSnapshot) -> some View {
        if let session = voiceprint.source.flatMap({ Self.session(id: $0.sessionID, in: modelContext) }) {
            Text("\(session.title) · \(session.createdAt.formatted(date: .abbreviated, time: .omitted))")
        } else {
            Text("Unknown session")
                .foregroundStyle(.secondary)
        }
    }

    /// The title and date of the recording or imported session with `id`, or `nil` when neither
    /// exists any more.
    static func session(id: UUID, in context: ModelContext) -> (title: String, createdAt: Date)? {
        let targetID = id
        var recordings = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == targetID })
        recordings.fetchLimit = 1
        if let recording = try? context.fetch(recordings).first {
            return (recording.title, recording.createdAt)
        }
        var imports = FetchDescriptor<ImportedSession>(predicate: #Predicate { $0.id == targetID })
        imports.fetchLimit = 1
        if let imported = try? context.fetch(imports).first {
            return (imported.title, imported.createdAt)
        }
        return nil
    }
}
