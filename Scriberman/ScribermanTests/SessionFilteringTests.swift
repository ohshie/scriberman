import Foundation
import Testing
@testable import Scriberman

/// The filtering both the window and the extension API run over sessions.
@MainActor
struct SessionFilteringTests {
    private func recording(_ title: String, spoken: String? = nil, tags: [RecordingTag] = []) -> JobsViewModel.SessionListItem {
        let session = RecordingSession(duration: 8, micAudioURL: "/tmp/audio.wav", title: title, status: .done)
        if let spoken {
            session.transcript = Transcript(fullText: spoken, segments: [], speakers: [])
        }
        session.tags = tags
        return .recording(session)
    }

    private func imported(_ title: String, spoken: String? = nil) -> JobsViewModel.SessionListItem {
        let session = ImportedSession(
            duration: 8,
            title: title,
            originalFileName: "talk.m4a",
            originalFormat: "m4a",
            status: .done
        )
        if let spoken {
            session.transcript = Transcript(fullText: spoken, segments: [], speakers: [])
        }
        return .imported(session)
    }

    @Test("No query and no tags keep every item in its order")
    func noFilter() {
        let items = [recording("A"), imported("B"), recording("C")]

        let result = SessionFiltering.filter(items, query: nil, tagIDs: [])

        #expect(result.map(\.id) == items.map(\.id))
    }

    @Test("A query matches the title or the transcript, ignoring case and diacritics")
    func query() {
        let byTitle = recording("Migration planning")
        let byTranscript = imported("Talk", spoken: "the café migration")
        let neither = recording("Standup", spoken: "nothing")

        let result = SessionFiltering.filter([byTitle, byTranscript, neither], query: "MIGRATION", tagIDs: [])
        let accented = SessionFiltering.filter([byTitle, byTranscript, neither], query: "cafe", tagIDs: [])

        #expect(result.map(\.id) == [byTitle.id, byTranscript.id])
        #expect(accented.map(\.id) == [byTranscript.id])
    }

    @Test("A query of only whitespace applies no search")
    func blankQuery() {
        let items = [recording("A"), recording("B")]

        #expect(SessionFiltering.filter(items, query: "   ", tagIDs: []).count == 2)
        #expect(SessionFiltering.activeQuery("  \n ") == nil)
        #expect(SessionFiltering.activeQuery("  x ") == "x")
    }

    @Test("Tags keep recordings carrying any of them; untagged kinds drop out")
    func tags() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let client = RecordingTag(name: "Client", colorHex: "445566")
        let other = RecordingTag(name: "Other", colorHex: "778899")
        let withWork = recording("A", tags: [work])
        let withClient = recording("B", tags: [client])
        let withOther = recording("C", tags: [other])
        let importedItem = imported("D")

        let result = SessionFiltering.filter(
            [withWork, withClient, withOther, importedItem],
            query: nil,
            tagIDs: [work.id, client.id]
        )

        #expect(result.map(\.id) == [withWork.id, withClient.id])
    }

    @Test("A tag no item carries leaves nothing")
    func absentTag() {
        let work = RecordingTag(name: "Work", colorHex: "112233")

        let result = SessionFiltering.filter([recording("A"), imported("B")], query: nil, tagIDs: [work.id])

        #expect(result.isEmpty)
    }

    @Test("Query and tags combine")
    func queryAndTags() {
        let work = RecordingTag(name: "Work", colorHex: "112233")
        let match = recording("Migration", tags: [work])
        let wrongTag = recording("Migration")
        let wrongTitle = recording("Standup", tags: [work])

        let result = SessionFiltering.filter([match, wrongTag, wrongTitle], query: "migration", tagIDs: [work.id])

        #expect(result.map(\.id) == [match.id])
    }
}
