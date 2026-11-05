import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// `GET /v1/sessions`, `/v1/sessions/latest` and `/v1/sessions/{id}`, through `admit` and `handle`.
@MainActor
struct ExtensionAPISessionsTests {
    struct TagBody: Decodable, Equatable {
        let id: String
        let name: String
    }

    struct Row: Decodable {
        let id: String
        let title: String
        let createdAt: String
        let duration: Double
        let status: String
        let tags: [TagBody]
    }

    struct ListBody: Decodable {
        let sessions: [Row]
    }

    struct TransformationBody: Decodable, Equatable {
        let id: String
        let promptName: String
        let modelId: String
        let resultText: String
        let createdAt: String
    }

    struct DetailBody: Decodable {
        let id: String
        let title: String
        let createdAt: String
        let duration: Double
        let status: String
        let tags: [TagBody]
        let transcript: String?
        let transformations: [TransformationBody]
    }

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - Helpers

    private func date(_ minutes: Int) -> Date {
        base.addingTimeInterval(TimeInterval(minutes * 60))
    }

    @discardableResult
    private func addRecording(
        _ fixture: ExtensionAPIFixture,
        title: String = "Session",
        at minutes: Int = 0,
        id: UUID = UUID(),
        status: RecordingStatus = .done,
        spoken: String? = nil,
        tags: [RecordingTag] = []
    ) throws -> RecordingSession {
        let session = RecordingSession(
            id: id,
            createdAt: date(minutes),
            duration: 90,
            micAudioURL: "/tmp/audio.wav",
            title: title,
            status: status
        )
        if let spoken {
            session.transcript = transcript(spoken)
        }
        fixture.sessionContext.insert(session)
        session.tags = tags
        try fixture.sessionContext.save()
        return session
    }

    @discardableResult
    private func addImported(
        _ fixture: ExtensionAPIFixture,
        title: String = "Imported",
        at minutes: Int = 0,
        id: UUID = UUID(),
        spoken: String? = nil
    ) throws -> ImportedSession {
        let session = ImportedSession(
            id: id,
            createdAt: date(minutes),
            duration: 30,
            title: title,
            originalFileName: "talk.m4a",
            originalFormat: "m4a",
            status: .done
        )
        if let spoken {
            session.transcript = transcript(spoken)
        }
        fixture.sessionContext.insert(session)
        try fixture.sessionContext.save()
        return session
    }

    private func addTag(_ fixture: ExtensionAPIFixture, _ name: String) throws -> RecordingTag {
        let tag = RecordingTag(name: name, colorHex: "112233")
        fixture.sessionContext.insert(tag)
        try fixture.sessionContext.save()
        return tag
    }

    private func transcript(_ text: String) -> Transcript {
        Transcript(
            fullText: text,
            segments: [TranscriptSegment(speakerId: "S1", text: text, startTime: 0, endTime: 2)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#4F46E5")]
        )
    }

    private func list(_ fixture: ExtensionAPIFixture, _ signer: ExtensionAPITestSigner, _ target: String) async throws -> [Row] {
        let response = await fixture.sendSigned(signer, "GET", target)
        try #require(response.status == 200)
        return try JSONDecoder().decode(ListBody.self, from: response.body).sessions
    }

    private func detail(_ response: HTTPResponse) throws -> DetailBody {
        try JSONDecoder().decode(DetailBody.self, from: response.body)
    }

    private func makeJobsViewModel(exportingTo url: URL? = nil) -> JobsViewModel {
        let retranscriptionService = RetranscriptionService(
            transcriptionService: TranscriptionService(),
            extractSamples: { _ in (mic: [0.1], app: nil) },
            prepareModelsHandler: { _ in },
            transcribePassFromSamplesHandler: { _, _, _, _, _ in TranscriptionPassRunner.PassResult() }
        )
        return JobsViewModel(
            workspaceService: MockWorkspaceService(),
            transcriptionService: MockTranscriptionService(),
            retranscriptionService: retranscriptionService,
            audioImportService: AudioImportService(
                retranscriptionService: retranscriptionService,
                probeAudio: { url in
                    AudioImportProbeResult(
                        title: url.lastPathComponent,
                        originalFileName: url.lastPathComponent,
                        originalFormat: "m4a",
                        duration: 0
                    )
                },
                readChannelSamples: { _ in DecodedAudio(channels: [[0.1]], sampleRate: 48_000) },
                writeMonoAAC: { _, _ in },
                retranscribe: { _, _, _, _ in }
            ),
            savePanelPresenter: { _ in url }
        )
    }

    // MARK: - List

    @Test("The list holds recorded and imported sessions, newest first, with their row fields")
    func listsBothKinds() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let work = try addTag(fixture, "Work")
        let recording = try addRecording(fixture, title: "Standup", at: 0, status: .done, tags: [work])
        let imported = try addImported(fixture, title: "Keynote", at: 10)

        let rows = try await list(fixture, signer, "/v1/sessions")

        #expect(rows.map(\.id) == ["imported:\(imported.id.uuidString)", "recording:\(recording.id.uuidString)"])
        let recordingRow = rows[1]
        #expect(recordingRow.title == "Standup")
        #expect(recordingRow.duration == 90)
        #expect(recordingRow.status == "done")
        #expect(recordingRow.tags == [TagBody(id: work.id.uuidString, name: "Work")])
        #expect(ISO8601DateFormatter().date(from: recordingRow.createdAt) == recording.createdAt)
        #expect(rows[0].tags.isEmpty)
        #expect(rows[0].title == "Keynote")
    }

    @Test("Sessions created at the same moment are ordered by id")
    func tiesByID() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        try addRecording(fixture, at: 5, id: high)
        try addImported(fixture, at: 5, id: high)
        try addRecording(fixture, at: 5, id: low)

        let rows = try await list(fixture, signer, "/v1/sessions")

        #expect(rows.map(\.id) == [
            "imported:\(high.uuidString)",
            "recording:\(low.uuidString)",
            "recording:\(high.uuidString)"
        ])
    }

    @Test("Search matches titles and transcript text")
    func search() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let byTitle = try addRecording(fixture, title: "Migration planning", at: 0)
        let byTranscript = try addImported(fixture, title: "Talk", at: 1, spoken: "we postpone the migration")
        try addRecording(fixture, title: "Standup", at: 2, spoken: "nothing to report")

        let rows = try await list(fixture, signer, "/v1/sessions?q=migration")
        let none = try await list(fixture, signer, "/v1/sessions?q=kubernetes")
        let encoded = try await list(fixture, signer, "/v1/sessions?q=postpone%20the")

        #expect(rows.map(\.id) == ["imported:\(byTranscript.id.uuidString)", "recording:\(byTitle.id.uuidString)"])
        #expect(none.isEmpty)
        #expect(encoded.map(\.id) == ["imported:\(byTranscript.id.uuidString)"])
    }

    @Test("A tag filter keeps recordings carrying it; imported sessions drop out")
    func tagFilter() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let work = try addTag(fixture, "Work")
        let client = try addTag(fixture, "Client")
        let tagged = try addRecording(fixture, title: "Planning", at: 0, tags: [work])
        try addRecording(fixture, title: "Other", at: 1, tags: [client])
        try addImported(fixture, at: 2)
        let unused = try addTag(fixture, "Unused")

        let rows = try await list(fixture, signer, "/v1/sessions?tag=\(work.id.uuidString)")
        let combined = try await list(fixture, signer, "/v1/sessions?tag=\(work.id.uuidString)&q=other")
        let empty = try await list(fixture, signer, "/v1/sessions?tag=\(unused.id.uuidString)")

        #expect(rows.map(\.id) == ["recording:\(tagged.id.uuidString)"])
        #expect(combined.isEmpty)
        #expect(empty.isEmpty)
    }

    @Test("Paging: the limit defaults to 50 and offset skips rows in order")
    func paging() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        var sessions: [RecordingSession] = []
        for minute in 0..<55 {
            sessions.append(try addRecording(fixture, title: "S\(minute)", at: minute))
        }
        let newestFirst = sessions.reversed().map { "recording:\($0.id.uuidString)" }

        let firstPage = try await list(fixture, signer, "/v1/sessions")
        let page = try await list(fixture, signer, "/v1/sessions?limit=3&offset=2")
        let tail = try await list(fixture, signer, "/v1/sessions?limit=200&offset=50")
        let past = try await list(fixture, signer, "/v1/sessions?offset=60")

        #expect(firstPage.map(\.id) == Array(newestFirst.prefix(50)))
        #expect(page.map(\.id) == Array(newestFirst[2..<5]))
        #expect(tail.map(\.id) == Array(newestFirst[50...]))
        #expect(past.isEmpty)
    }

    @Test(
        "Bad query values are invalid requests",
        arguments: [
            "limit=0", "limit=201", "limit=-1", "limit=ten", "limit=", "offset=-1", "offset=x",
            "tag=not-a-uuid", "tag=", "limit=5&limit=6", "q=a&q=b"
        ]
    )
    func badQuery(query: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions?\(query)")

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_request")
    }

    @Test("API search and filter neither read nor change the window's query and tag selection")
    func windowUntouched() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let jobs = makeJobsViewModel()
        fixture.renderTranscript = { jobs.renderedTranscript(for: $0) }
        let work = try addTag(fixture, "Work")
        let client = try addTag(fixture, "Client")
        let workSession = try addRecording(fixture, title: "Planning", at: 0, tags: [work])
        let clientSession = try addRecording(fixture, title: "Review", at: 1, tags: [client])
        jobs.searchQuery = "Planning"
        jobs.selectedTagIDs = [work.id]

        let all = try await list(fixture, signer, "/v1/sessions")
        let filtered = try await list(fixture, signer, "/v1/sessions?q=review&tag=\(client.id.uuidString)")

        #expect(all.count == 2)
        #expect(filtered.map(\.id) == ["recording:\(clientSession.id.uuidString)"])
        #expect(jobs.searchQuery == "Planning")
        #expect(jobs.selectedTagIDs == [work.id])
        let windowItems = jobs.sessionItems(recordingSessions: [workSession, clientSession], importedSessions: [], preserving: nil)
        #expect(windowItems.map(\.id) == ["recording:\(workSession.id.uuidString)"])
    }

    // MARK: - Latest

    @Test("Latest is the newest session with a transcript, skipping one still recording and ones without a transcript")
    func latest() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let jobs = makeJobsViewModel()
        fixture.renderTranscript = { jobs.renderedTranscript(for: $0) }
        try addRecording(fixture, title: "Old", at: 0, spoken: "old words")
        let expected = try addImported(fixture, title: "Talk", at: 1, spoken: "talk words")
        try addRecording(fixture, title: "No transcript", at: 2)
        try addRecording(fixture, title: "Live", at: 3, status: .recording, spoken: "live words")

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions/latest")

        #expect(response.status == 200)
        let body = try detail(response)
        #expect(body.id == "imported:\(expected.id.uuidString)")
        #expect(body.transcript == jobs.renderedTranscript(for: expected))
    }

    @Test("Latest breaks a tie on created date by id")
    func latestTie() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        try addRecording(fixture, at: 0, id: high, spoken: "a")
        try addRecording(fixture, at: 0, id: low, spoken: "b")

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions/latest")

        #expect(try detail(response).id == "recording:\(low.uuidString)")
    }

    @Test("Latest is not_found when no session has a transcript")
    func latestNone() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        try addRecording(fixture, title: "No transcript", at: 0)
        try addRecording(fixture, title: "Live", at: 1, status: .recording, spoken: "live words")

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions/latest")

        #expect(response.status == 404)
        #expect(errorCode(response) == "not_found")
    }

    // MARK: - Detail

    @Test("Detail transcript equals what export writes, and the history keeps its order")
    func detailMatchesExport() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let jobs = makeJobsViewModel(exportingTo: outputURL)
        fixture.renderTranscript = { jobs.renderedTranscript(for: $0) }
        let work = try addTag(fixture, "Work")
        let session = try addRecording(fixture, title: "Planning", at: 0, spoken: "hello there", tags: [work])
        let first = AITransformation(promptName: "Summary", modelID: "model-a", resultText: "first", createdAt: date(5))
        let second = AITransformation(promptName: "Actions", modelID: "model-b", resultText: "second", createdAt: date(1))
        session.aiTransformations = [first, second]
        try fixture.sessionContext.save()

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions/recording:\(session.id.uuidString)")
        try await jobs.exportTranscript(for: session)
        let written = try String(contentsOf: outputURL, encoding: .utf8)

        #expect(response.status == 200)
        let body = try detail(response)
        #expect(body.id == "recording:\(session.id.uuidString)")
        #expect(body.title == "Planning")
        #expect(body.status == "done")
        #expect(body.duration == 90)
        #expect(body.tags == [TagBody(id: work.id.uuidString, name: "Work")])
        #expect(body.transcript == written)
        #expect(body.transformations.map(\.id) == [first.id.uuidString, second.id.uuidString])
        #expect(body.transformations[0].promptName == "Summary")
        #expect(body.transformations[0].modelId == "model-a")
        #expect(body.transformations[0].resultText == "first")
        #expect(ISO8601DateFormatter().date(from: body.transformations[0].createdAt) == first.createdAt)
    }

    @Test("Detail of a session without a transcript carries a null transcript and an empty history")
    func detailWithoutTranscript() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let jobs = makeJobsViewModel()
        fixture.renderTranscript = { jobs.renderedTranscript(for: $0) }
        let imported = try addImported(fixture, title: "Talk", at: 0)

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions/imported:\(imported.id.uuidString)")

        #expect(response.status == 200)
        let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(object["transcript"] is NSNull)
        let body = try detail(response)
        #expect(body.transformations.isEmpty)
        #expect(body.tags.isEmpty)
    }

    @Test("A percent-encoded id is accepted")
    func encodedID() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let session = try addRecording(fixture, at: 0)

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions/recording%3A\(session.id.uuidString)")

        #expect(response.status == 200)
        #expect(try detail(response).id == "recording:\(session.id.uuidString)")
    }

    @Test("An unknown id is not_found, including an id of the other kind")
    func unknownID() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let session = try addRecording(fixture, at: 0)

        let unknown = await fixture.sendSigned(signer, "GET", "/v1/sessions/recording:\(UUID().uuidString)")
        let otherKind = await fixture.sendSigned(signer, "GET", "/v1/sessions/imported:\(session.id.uuidString)")

        #expect(unknown.status == 404)
        #expect(errorCode(unknown) == "not_found")
        #expect(otherKind.status == 404)
        #expect(errorCode(otherKind) == "not_found")
    }

    @Test(
        "A malformed id is an invalid request",
        arguments: [
            "not-an-id", "recording:", "recording:not-a-uuid", "pending:\(UUID().uuidString)",
            UUID().uuidString, "recording:\(UUID().uuidString):x"
        ]
    )
    func malformedID(id: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()

        let response = await fixture.sendSigned(signer, "GET", "/v1/sessions/\(id)")

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_request")
    }
}
