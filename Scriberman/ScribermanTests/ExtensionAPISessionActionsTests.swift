import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// `POST /v1/sessions/{id}/open`, `/export` and `/reveal`, through `admit` and `handle`.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExtensionAPISessionActionsTests {
    private struct ExportBody: Decodable {
        let outcome: String
    }

    private let fixture = ExtensionAPIFixture()
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtensionAPISessionActionsTests-\(UUID().uuidString)", isDirectory: true)
    private var workspace: Workspace { Workspace(rootURL: root) }

    /// What the actions did, in order.
    private final class Recorder {
        var requests: [AppState.SessionRequest] = []
        var windowShown = 0
        var revealed: [URL] = []
        /// What the save panel returns; called once the panel "closes".
        var savePanel: @MainActor (String) async -> URL? = { _ in nil }
        var workspace: Result<Workspace, WorkspaceError> = .failure(.notConfigured)
        /// `windowShown` at each time the save panel opened.
        var panelsOpened: [Int] = []
    }

    private let recorder = Recorder()

    init() throws {
        try FileManager.default.createDirectory(at: workspace.recordingsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.importsURL, withIntermediateDirectories: true)
        recorder.workspace = .success(workspace)
        let jobs = makeJobsViewModel()
        fixture.handler.sessionActions = ExtensionAPISessionActions(
            requestSession: { [recorder] in recorder.requests.append($0) },
            showWindow: { [recorder] in recorder.windowShown += 1 },
            export: { session, mayWrite in await jobs.exportTranscript(for: session, mayWrite: mayWrite) },
            authorizedWorkspace: { [recorder] () throws(WorkspaceError) in try recorder.workspace.get() },
            revealInFinder: { [recorder] in recorder.revealed.append($0) }
        )
    }

    private func makeJobsViewModel() -> JobsViewModel {
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
            audioImportService: AudioImportService(retranscriptionService: retranscriptionService),
            transcriptExportService: TranscriptExportService(),
            savePanelPresenter: { [recorder] name in
                recorder.panelsOpened.append(recorder.windowShown)
                return await recorder.savePanel(name)
            }
        )
    }

    // MARK: - Fixtures

    private func makeRecording(folderName: String = UUID().uuidString, createFolder: Bool = true, transcript: Bool = true) throws -> RecordingSession {
        let folder = workspace.recordingsURL.appendingPathComponent(folderName, isDirectory: true)
        if createFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: folder.appendingPathComponent("mic.wav").path,
            title: "Standup",
            status: .done
        )
        if transcript {
            session.transcript = Self.transcript("Hello there")
        }
        fixture.container.mainContext.insert(session)
        try fixture.container.mainContext.save()
        return session
    }

    private func makeImported(createFolder: Bool = true, mixdown: Bool = true) throws -> ImportedSession {
        let folder = workspace.importsURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        if createFolder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let session = ImportedSession(
            duration: 10,
            title: "Keynote",
            originalFileName: "talk.m4a",
            originalFormat: "m4a",
            status: .done
        )
        if mixdown {
            session.mixdownURL = folder.appendingPathComponent("mixdown.m4a").path
        }
        session.transcript = Self.transcript("Imported words")
        fixture.container.mainContext.insert(session)
        try fixture.container.mainContext.save()
        return session
    }

    private static func transcript(_ text: String) -> Transcript {
        Transcript(
            fullText: text,
            segments: [TranscriptSegment(speakerId: "S1", text: text, startTime: 0, endTime: 1, audioSource: .mic)],
            speakers: [TranscriptSpeaker(id: "S1", label: "Speaker 1", colorHex: "#111111")]
        )
    }

    private func id(_ session: RecordingSession) -> String { "recording:\(session.id.uuidString)" }
    private func id(_ session: ImportedSession) -> String { "imported:\(session.id.uuidString)" }

    private func post(_ signer: ExtensionAPITestSigner, _ sessionID: String, _ action: String) async -> HTTPResponse {
        await fixture.sendSigned(signer, "POST", "/v1/sessions/\(sessionID)/\(action)")
    }

    private func code(_ response: HTTPResponse) throws -> String {
        try JSONDecoder().decode(ExtensionAPIErrorBody.self, from: response.body).code
    }

    private func outcome(_ response: HTTPResponse) throws -> String {
        try JSONDecoder().decode(ExportBody.self, from: response.body).outcome
    }

    private func exportURL() -> URL {
        root.appendingPathComponent("export-\(UUID().uuidString).md")
    }

    /// Whether the session is still in the store, read from a second context.
    private func storedCount() throws -> Int {
        let context = ModelContext(fixture.container)
        return try context.fetchCount(FetchDescriptor<RecordingSession>())
            + context.fetchCount(FetchDescriptor<ImportedSession>())
    }

    // MARK: - Open

    @Test("Opening a recorded session requests it and brings the window forward")
    func openRecorded() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()

        let response = await post(signer, id(session), "open")

        #expect(response.status == 200)
        #expect(recorder.requests == [.recording(session.id)])
        #expect(recorder.windowShown == 1)
    }

    @Test("Opening an imported session requests it as an imported session")
    func openImported() async throws {
        let signer = try await fixture.pair()
        let session = try makeImported()

        let response = await post(signer, id(session), "open")

        #expect(response.status == 200)
        #expect(recorder.requests == [.imported(session.id)])
        #expect(recorder.windowShown == 1)
    }

    @Test("Opening an unknown or deleted session answers not_found and requests nothing")
    func openUnknown() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()
        let sessionID = id(session)
        fixture.container.mainContext.delete(session)
        try fixture.container.mainContext.save()

        let response = await post(signer, sessionID, "open")

        #expect(response.status == 404)
        #expect(try code(response) == "not_found")
        #expect(recorder.requests.isEmpty)
        #expect(recorder.windowShown == 0)
    }

    @Test("A malformed id answers invalid_request on every action", arguments: ["open", "export", "reveal"])
    func malformedID(action: String) async throws {
        let signer = try await fixture.pair()

        let response = await post(signer, "recording:not-a-uuid", action)

        #expect(response.status == 400)
        #expect(try code(response) == "invalid_request")
        #expect(recorder.requests.isEmpty)
        #expect(recorder.windowShown == 0)
        #expect(recorder.revealed.isEmpty)
    }

    @Test("An unknown session answers not_found on every action", arguments: ["open", "export", "reveal"])
    func unknownID(action: String) async throws {
        let signer = try await fixture.pair()

        let response = await post(signer, "imported:\(UUID().uuidString)", action)

        #expect(response.status == 404)
        #expect(try code(response) == "not_found")
        #expect(recorder.revealed.isEmpty)
    }

    // MARK: - Reveal

    @Test("Reveal selects the recorded session's folder in Finder")
    func revealRecorded() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording(folderName: "2026-11-05 Standup")

        let response = await post(signer, id(session), "reveal")

        #expect(response.status == 200)
        let revealed = try #require(recorder.revealed.first)
        #expect(revealed.standardizedFileURL.resolvingSymlinksInPath()
            == workspace.recordingsURL.appendingPathComponent("2026-11-05 Standup").standardizedFileURL.resolvingSymlinksInPath())
        #expect(recorder.revealed.count == 1)
    }

    @Test("Reveal selects the imported session's folder in Finder")
    func revealImported() async throws {
        let signer = try await fixture.pair()
        let session = try makeImported()
        let folder = URL(fileURLWithPath: try #require(session.mixdownURL)).deletingLastPathComponent()

        let response = await post(signer, id(session), "reveal")

        #expect(response.status == 200)
        #expect(recorder.revealed.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            == [folder.standardizedFileURL.resolvingSymlinksInPath()])
    }

    @Test("Reveal of a missing folder answers not_found")
    func revealMissingFolder() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording(createFolder: false)

        let response = await post(signer, id(session), "reveal")

        #expect(response.status == 404)
        #expect(try code(response) == "not_found")
        #expect(recorder.revealed.isEmpty)
    }

    @Test("Reveal of an imported session with no folder answers not_found")
    func revealImportedWithoutFolder() async throws {
        let signer = try await fixture.pair()
        let session = try makeImported(mixdown: false)

        let response = await post(signer, id(session), "reveal")

        #expect(response.status == 404)
        #expect(try code(response) == "not_found")
        #expect(recorder.revealed.isEmpty)
    }

    @Test("Reveal of a folder outside the workspace answers not_found")
    func revealOutsideWorkspace() async throws {
        let signer = try await fixture.pair()
        let outside = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let session = try makeRecording()
        session.micAudioURL = workspace.recordingsURL.appendingPathComponent("../elsewhere/mic.wav").path
        try fixture.container.mainContext.save()

        let response = await post(signer, id(session), "reveal")

        #expect(response.status == 404)
        #expect(try code(response) == "not_found")
        #expect(recorder.revealed.isEmpty)
    }

    @Test("Reveal without an authorized workspace answers workspace_unavailable")
    func revealWithoutWorkspace() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()
        recorder.workspace = .failure(.accessDenied)

        let response = await post(signer, id(session), "reveal")

        #expect(response.status == 503)
        #expect(try code(response) == "workspace_unavailable")
        #expect(recorder.revealed.isEmpty)
    }

    // MARK: - Export

    @Test("A saved export writes the transcript, brings Scriberman forward and answers saved")
    func exportSaved() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()
        let destination = exportURL()
        recorder.savePanel = { _ in destination }

        let response = await post(signer, id(session), "export")

        #expect(response.status == 200)
        #expect(try outcome(response) == "saved")
        #expect(recorder.panelsOpened == [1])
        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written.contains("Hello there"))
    }

    @Test("Exporting an imported session writes its transcript")
    func exportImported() async throws {
        let signer = try await fixture.pair()
        let session = try makeImported()
        let destination = exportURL()
        recorder.savePanel = { _ in destination }

        let response = await post(signer, id(session), "export")

        #expect(response.status == 200)
        #expect(try outcome(response) == "saved")
        #expect(try String(contentsOf: destination, encoding: .utf8).contains("Imported words"))
    }

    @Test("A cancelled save panel answers cancelled")
    func exportCancelled() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()
        recorder.savePanel = { _ in nil }

        let response = await post(signer, id(session), "export")

        #expect(response.status == 200)
        #expect(try outcome(response) == "cancelled")
    }

    @Test("A write that fails answers failed")
    func exportFailed() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()
        let destination = root.appendingPathComponent("missing-folder/out.md")
        recorder.savePanel = { _ in destination }

        let response = await post(signer, id(session), "export")

        #expect(response.status == 200)
        #expect(try outcome(response) == "failed")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("A session with no transcript answers no_transcript without opening the save panel")
    func exportWithoutTranscript() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording(transcript: false)

        let response = await post(signer, id(session), "export")

        #expect(response.status == 409)
        #expect(try code(response) == "no_transcript")
        #expect(recorder.panelsOpened.isEmpty)
    }

    @Test("A session deleted while the save panel is open: nothing written, not_found")
    func exportDeletedDuringPanel() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()
        let destination = exportURL()
        let context = fixture.container.mainContext
        recorder.savePanel = { _ in
            context.delete(session)
            try? context.save()
            return destination
        }

        let response = await post(signer, id(session), "export")

        #expect(response.status == 404)
        #expect(try code(response) == "not_found")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try storedCount() == 0)
    }

    @Test("A client revoked while the save panel is open: nothing written, unauthorized")
    func exportRevokedDuringPanel() async throws {
        let signer = try await fixture.pair()
        let session = try makeRecording()
        let destination = exportURL()
        recorder.savePanel = { [fixture] _ in
            fixture.store.revoke(signer.clientID)
            return destination
        }

        let response = await post(signer, id(session), "export")

        #expect(response.status == 401)
        #expect(try code(response) == "unauthorized")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

/// The window selects the session an open request names.
@MainActor
struct AppShellSessionRequestTests {
    private let recording = RecordingSession(duration: 10, micAudioURL: "/tmp/mic.wav", title: "Standup")
    private let imported = ImportedSession(
        duration: 10,
        title: "Keynote",
        originalFileName: "talk.m4a",
        originalFormat: "m4a",
        status: .done
    )

    private func item(for request: AppState.SessionRequest) -> JobsViewModel.SessionListItem? {
        AppShellView.sessionItem(
            for: request,
            pendingSession: nil,
            recordingSessions: [recording],
            importedSessions: [imported]
        )
    }

    @Test("A request for a recorded session selects it")
    func recorded() {
        #expect(item(for: .recording(recording.id)) == .recording(recording))
    }

    @Test("A request for an imported session selects it")
    func importedSession() {
        #expect(item(for: .imported(imported.id)) == .imported(imported))
    }

    @Test("A request for a session not in the list selects nothing yet")
    func notListed() {
        #expect(item(for: .imported(recording.id)) == nil)
        #expect(item(for: .recording(imported.id)) == nil)
    }
}
