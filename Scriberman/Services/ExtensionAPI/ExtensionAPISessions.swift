import Foundation
import SwiftData

/// A kind-qualified session id: `recording:<uuid>` or `imported:<uuid>`.
struct ExtensionAPISessionID: Hashable, Sendable {
    enum Kind: String, Sendable {
        case recording
        case imported
    }

    let kind: Kind
    let uuid: UUID

    /// Parses a path segment, percent-decoding it first. Nil for anything malformed.
    init?(pathSegment: String) {
        guard let decoded = pathSegment.removingPercentEncoding else { return nil }
        let parts = decoded.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let kind = Kind(rawValue: String(parts[0])),
              let uuid = UUID(uuidString: String(parts[1]))
        else {
            return nil
        }
        self.kind = kind
        self.uuid = uuid
    }

    init(kind: Kind, uuid: UUID) {
        self.kind = kind
        self.uuid = uuid
    }

    var string: String {
        "\(kind.rawValue):\(uuid.uuidString)"
    }
}

/// A session as the API lists it.
struct ExtensionAPISessionRow: Encodable, Sendable {
    struct Tag: Encodable, Sendable {
        let id: String
        let name: String
    }

    let id: String
    let title: String
    let createdAt: String
    let duration: TimeInterval
    let status: String
    let tags: [Tag]
}

/// A session with its rendered transcript and AI transformation history.
struct ExtensionAPISessionDetail: Encodable, Sendable {
    struct Transformation: Encodable, Sendable {
        let id: String
        let promptName: String
        let modelId: String
        let resultText: String
        let createdAt: String
    }

    let row: ExtensionAPISessionRow
    /// Nil when the session has no transcript; encoded as `null`.
    let transcript: String?
    let transformations: [Transformation]

    private enum CodingKeys: String, CodingKey {
        case transcript
        case transformations
    }

    func encode(to encoder: any Encoder) throws {
        try row.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcript, forKey: .transcript)
        try container.encode(transformations, forKey: .transformations)
    }
}

/// Reads recorded and imported sessions for the API and hands out plain values.
@MainActor
final class ExtensionAPISessionCatalog {
    private let context: ModelContext?
    private let renderTranscript: @MainActor (any TranscribableSession) -> String?

    /// `renderTranscript` is `JobsViewModel.renderedTranscript(for:)` in the app, so the API's
    /// transcript equals what export writes.
    init(context: ModelContext?, renderTranscript: @escaping @MainActor (any TranscribableSession) -> String?) {
        self.context = context
        self.renderTranscript = renderTranscript
    }

    /// Recorded and imported sessions filtered by `query` and `tagID`, newest first with ties
    /// broken by id, then paged.
    func sessions(query: String?, tagID: UUID?, limit: Int, offset: Int) -> [ExtensionAPISessionRow] {
        let filtered = SessionFiltering.filter(allItems(), query: query, tagIDs: tagID.map { [$0] } ?? [])
        return Self.ordered(filtered).dropFirst(offset).prefix(limit).compactMap(Self.row)
    }

    /// The newest session with a transcript that is not still recording.
    func latest() -> ExtensionAPISessionDetail? {
        let candidate = Self.ordered(allItems()).first { item in
            guard let session = Self.session(of: item) else { return false }
            return session.status != .recording && session.displayedTranscript != nil
        }
        return candidate.flatMap(detail)
    }

    func detail(_ id: ExtensionAPISessionID) -> ExtensionAPISessionDetail? {
        guard let context else { return nil }
        let uuid = id.uuid
        let item: JobsViewModel.SessionListItem?
        switch id.kind {
        case .recording:
            let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == uuid })
            item = (try? context.fetch(descriptor))?.first.map(JobsViewModel.SessionListItem.recording)
        case .imported:
            let descriptor = FetchDescriptor<ImportedSession>(predicate: #Predicate { $0.id == uuid })
            item = (try? context.fetch(descriptor))?.first.map(JobsViewModel.SessionListItem.imported)
        }
        return item.flatMap(detail)
    }

    // MARK: - Private

    private func allItems() -> [JobsViewModel.SessionListItem] {
        guard let context else { return [] }
        let recordings = (try? context.fetch(FetchDescriptor<RecordingSession>())) ?? []
        let imported = (try? context.fetch(FetchDescriptor<ImportedSession>())) ?? []
        return recordings.map(JobsViewModel.SessionListItem.recording) + imported.map(JobsViewModel.SessionListItem.imported)
    }

    private static func ordered(_ items: [JobsViewModel.SessionListItem]) -> [JobsViewModel.SessionListItem] {
        items.sorted { lhs, rhs in
            lhs.createdAt != rhs.createdAt ? lhs.createdAt > rhs.createdAt : lhs.id < rhs.id
        }
    }

    private static func session(of item: JobsViewModel.SessionListItem) -> (any TranscribableSession)? {
        switch item {
        case .pending: nil
        case .recording(let session): session
        case .imported(let session): session
        }
    }

    private static func row(_ item: JobsViewModel.SessionListItem) -> ExtensionAPISessionRow? {
        guard let session = session(of: item) else { return nil }
        let tags: [ExtensionAPISessionRow.Tag]
        if case .recording(let recording) = item {
            tags = recording.tags.map { .init(id: $0.id.uuidString, name: $0.name) }
        } else {
            tags = []
        }
        return ExtensionAPISessionRow(
            id: item.id,
            title: session.title,
            createdAt: formatDate(session.createdAt),
            duration: session.duration,
            status: session.status.persistedValue,
            tags: tags
        )
    }

    private func detail(_ item: JobsViewModel.SessionListItem) -> ExtensionAPISessionDetail? {
        guard let session = Self.session(of: item), let row = Self.row(item) else { return nil }
        return ExtensionAPISessionDetail(
            row: row,
            transcript: renderTranscript(session),
            transformations: session.aiTransformations.map {
                .init(
                    id: $0.id.uuidString,
                    promptName: $0.promptName,
                    modelId: $0.modelID,
                    resultText: $0.resultText,
                    createdAt: Self.formatDate($0.createdAt)
                )
            }
        )
    }

    /// ISO 8601 with time zone.
    private static func formatDate(_ date: Date) -> String {
        date.ISO8601Format()
    }
}
