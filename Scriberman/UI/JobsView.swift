import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct JobsView: View {
    enum SessionNavigationTarget: Hashable {
        case recording(UUID)
        case imported(UUID)
    }

    @ObservedObject var viewModel: JobsViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordingSession.createdAt, order: .reverse) private var recordingSessions: [RecordingSession]
    @Query(sort: \ImportedSession.createdAt, order: .reverse) private var importedSessions: [ImportedSession]
    @State private var navigationPath = NavigationPath()

    private var allItems: [JobsViewModel.SessionListItem] {
        let recordingItems = recordingSessions.map(JobsViewModel.SessionListItem.recording)
        let importedItems = importedSessions.map(JobsViewModel.SessionListItem.imported)
        return (recordingItems + importedItems).sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if allItems.isEmpty {
                    ContentUnavailableView("No Jobs", systemImage: "list.bullet.rectangle")
                } else {
                    List {
                        ForEach(allItems) { item in
                            switch item {
                            case .recording(let session):
                                RecordingSessionRow(
                                    session: session,
                                    onTranscribe: { viewModel.transcribe(session: session, context: modelContext) },
                                    onRetry: { viewModel.retry(session: session, context: modelContext) },
                                    onOpen: { navigationPath.append(SessionNavigationTarget.recording(session.id)) }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.delete(session: session, context: modelContext)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            case .imported(let session):
                                ImportedSessionRow(
                                    session: session,
                                    onRetry: { viewModel.retryImported(session: session, context: modelContext) },
                                    onOpen: { navigationPath.append(SessionNavigationTarget.imported(session.id)) }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.deleteImported(session: session, context: modelContext)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Jobs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openImportPanel()
                    } label: {
                        Label("Import Audio", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationDestination(for: SessionNavigationTarget.self) { target in
                switch target {
                case .recording(let sessionID):
                    if let session = recordingSessions.first(where: { $0.id == sessionID }) {
                        TranscriptDetailView(session: session)
                    } else {
                        ContentUnavailableView("Recording Not Found", systemImage: "exclamationmark.triangle")
                    }
                case .imported(let sessionID):
                    if let session = importedSessions.first(where: { $0.id == sessionID }) {
                        TranscriptDetailView(session: session)
                    } else {
                        ContentUnavailableView("Imported Session Not Found", systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
        .onDrop(of: [.audio, .fileURL], isTargeted: nil) { providers in
            let canHandle = providers.contains { provider in
                provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
            }
            guard canHandle else {
                return false
            }

            Task {
                let urls = await loadDroppedAudioURLs(from: providers)
                await viewModel.importAudio(urls: urls, context: modelContext)
            }
            return true
        }
        .task {
            await viewModel.refresh()
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Audio"
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]

        guard panel.runModal() == .OK else {
            return
        }

        Task {
            await viewModel.importAudio(urls: panel.urls, context: modelContext)
        }
    }

    private func loadDroppedAudioURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(from: provider), isAudioURL(url) {
                urls.append(url)
            }
        }
        return urls
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }
                if let string = item as? String,
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private func isAudioURL(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           contentType.conforms(to: .audio) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .audio)
    }
}
