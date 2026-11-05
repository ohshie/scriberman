import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// What the stand-in importer was given.
@MainActor
private final class ImportRecord {
    var calls: [(url: URL, contents: Data?, conversionEnded: @Sendable () -> Void)] = []
}

/// Percent-encodes everything but unreserved ASCII, as the extension sends the file name.
private func percentEncoded(_ name: String) -> String {
    let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return name.addingPercentEncoding(withAllowedCharacters: unreserved)!
}

private struct SessionIDBody: Decodable {
    let sessionId: String
}

@MainActor
private func eventually(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
extension ExtensionAPIFixture {
    /// The entries in the staging folder.
    var staged: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)) ?? []
    }

    /// The head of a signed import of `body`, with `fileNameHeader` sent as is (nil leaves it out).
    func importHead(
        _ signer: ExtensionAPITestSigner,
        signedBody: Data,
        fileNameHeader: String?,
        contentLength: Int? = nil,
        nonce: String = ExtensionAPITestSigner.randomNonce()
    ) -> HTTPRequestHead {
        var headers = signer.headers(method: "POST", target: "/v1/imports", body: signedBody, timestamp: now, nonce: nonce)
        if let fileNameHeader {
            headers.append(("X-Scriberman-File-Name", fileNameHeader))
        }
        return head("POST", "/v1/imports", headers: headers, contentLength: contentLength ?? signedBody.count)
    }

    func sendImport(
        _ signer: ExtensionAPITestSigner,
        name: String = "meeting.m4a",
        body: Data = Data("audio bytes".utf8),
        nonce: String = ExtensionAPITestSigner.randomNonce()
    ) async -> HTTPResponse {
        await send(importHead(signer, signedBody: body, fileNameHeader: percentEncoded(name), nonce: nonce), body: body)
    }

    /// Records every import call and answers with `id`.
    func recordImports(answering id: UUID = UUID()) -> ImportRecordHandle {
        let record = ImportRecord()
        importer = { url, conversionEnded in
            record.calls.append((url, try? Data(contentsOf: url), conversionEnded))
            return id
        }
        return ImportRecordHandle(record: record, id: id)
    }
}

@MainActor
struct ImportRecordHandle {
    fileprivate let record: ImportRecord
    let id: UUID

    var count: Int { record.calls.count }
    var url: URL? { record.calls.first?.url }
    var contents: Data? { record.calls.first?.contents }
    func endConversion() { record.calls.first?.conversionEnded() }
}

@MainActor
struct ExtensionAPIImportTests {
    // MARK: - Checks before the body

    @Test("A declared size over 1 GiB is refused before any body is read, and nothing is staged")
    func tooLarge() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let head = fixture.importHead(signer, signedBody: Data(), fileNameHeader: "meeting.m4a", contentLength: 1024 * 1024 * 1024 + 1)

        let admission = await fixture.handler.admit(head, peer: fixture.peer)

        guard case .refused(let response) = admission else {
            Issue.record("Expected a refusal, got \(admission)")
            return
        }
        #expect(response.status == 413)
        #expect(errorCode(response) == "payload_too_large")
        #expect(fixture.staged.isEmpty)
    }

    @Test("A declared size of exactly 1 GiB is admitted")
    func exactlyOneGiB() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let head = fixture.importHead(signer, signedBody: Data(), fileNameHeader: "meeting.m4a", contentLength: 1024 * 1024 * 1024)

        let admission = await fixture.handler.admit(head, peer: fixture.peer)

        guard case .admittedToFile(let upload) = admission else {
            Issue.record("Expected admission to a staged file, got \(admission)")
            return
        }
        upload.discard()
    }

    @Test(
        "Free space under twice the declared size is refused before any body is read",
        arguments: [Int64?.some(2 * 1000 - 1), Int64?.some(0), nil]
    )
    func insufficientSpace(available: Int64?) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        fixture.availableDiskSpace = available
        let imports = fixture.recordImports()

        let response = await fixture.sendImport(signer, body: Data(repeating: 1, count: 1000))

        #expect(response.status == 507)
        #expect(errorCode(response) == "insufficient_disk_space")
        #expect(fixture.staged.isEmpty)
        #expect(imports.count == 0)
    }

    @Test("Free space of exactly twice the declared size is enough")
    func exactlyTwiceSpace() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        fixture.availableDiskSpace = 2000
        _ = fixture.recordImports()

        let response = await fixture.sendImport(signer, body: Data(repeating: 1, count: 1000))

        #expect(response.status == 202)
    }

    @Test(
        "An invalid file name is refused before any body is read, and nothing is staged",
        arguments: [
            "",
            ".",
            "..",
            "a%2Fb.m4a",
            "a/b.m4a",
            "..%2Fescape.m4a",
            "%2Fescape.m4a",
            "a%00b.m4a",
            "%zz.m4a",
            String(repeating: "a", count: 252) + ".m4a",
            String(repeating: "%C3%A9", count: 126) + ".m4a",
        ]
    )
    func invalidName(header: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let body = Data("audio".utf8)

        let response = await fixture.send(fixture.importHead(signer, signedBody: body, fileNameHeader: header), body: body)

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_file_name")
        #expect(fixture.staged.isEmpty)
        #expect(imports.count == 0)
    }

    @Test("A request without a file name is refused as an invalid file name")
    func missingName() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let body = Data("audio".utf8)

        let response = await fixture.send(fixture.importHead(signer, signedBody: body, fileNameHeader: nil), body: body)

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_file_name")
        #expect(fixture.staged.isEmpty)
    }

    @Test("A name of exactly 255 bytes is accepted")
    func longestName() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let name = String(repeating: "a", count: 251) + ".m4a"

        let response = await fixture.sendImport(signer, name: name)

        #expect(response.status == 202)
        #expect(imports.url?.lastPathComponent == name)
    }

    @Test("A file name that is not audio is refused as not_audio before any body is read", arguments: ["notes.txt", "noextension"])
    func notAudioName(name: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()

        let response = await fixture.sendImport(signer, name: name)

        #expect(errorCode(response) == "not_audio")
        #expect(fixture.staged.isEmpty)
        #expect(imports.count == 0)
    }

    // MARK: - Success

    @Test("An import answers 202 with the new session id, signed")
    func accepted() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let nonce = ExtensionAPITestSigner.randomNonce()

        let response = await fixture.sendImport(signer, nonce: nonce)

        #expect(response.status == 202)
        let body = try JSONDecoder().decode(SessionIDBody.self, from: response.body)
        #expect(body.sessionId == "imported:\(imports.id.uuidString)")
        #expect(signer.verifies(response, nonce: nonce))
    }

    @Test("The importer gets the received bytes in a new directory under the original name")
    func stagedFile() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let body = Data((0..<5000).map { UInt8($0 % 251) })

        _ = await fixture.sendImport(signer, name: "Café meeting.m4a", body: body)

        let url = try #require(imports.url)
        #expect(url.lastPathComponent == "Café meeting.m4a")
        #expect(imports.contents == body)
        let directory = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        #expect(fixture.staged.map { $0.standardizedFileURL.resolvingSymlinksInPath() } == [directory])
    }

    @Test("Two imports of the same name are staged in different directories")
    func distinctDirectories() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let first = fixture.recordImports()
        _ = await fixture.sendImport(signer)
        let second = fixture.recordImports()
        _ = await fixture.sendImport(signer)

        let firstURL = try #require(first.url)
        let secondURL = try #require(second.url)
        #expect(firstURL.deletingLastPathComponent() != secondURL.deletingLastPathComponent())
    }

    @Test("The staged directory stays while conversion runs and is removed when it ends")
    func removedAfterConversion() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()

        _ = await fixture.sendImport(signer)
        #expect(fixture.staged.count == 1)

        imports.endConversion()
        #expect(fixture.staged.isEmpty)
    }

    // MARK: - Links

    @Test("A link in the staging folder under the upload's name is not followed")
    func linkInStagingRootIgnored() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let victim = fixture.stagingRoot.deletingLastPathComponent()
            .appendingPathComponent("victim-\(UUID().uuidString)")
        try Data("keep".utf8).write(to: victim)
        defer { try? FileManager.default.removeItem(at: victim) }
        try FileManager.default.createSymbolicLink(
            at: fixture.stagingRoot.appendingPathComponent("meeting.m4a"),
            withDestinationURL: victim
        )

        let response = await fixture.sendImport(signer, name: "meeting.m4a", body: Data("upload".utf8))

        #expect(response.status == 202)
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        #expect(imports.contents == Data("upload".utf8))
    }

    @Test("An existing link or file at the staged file's path is never written through")
    func existingTargetRefused() async throws {
        for makeLink in [true, false] {
            let fixture = ExtensionAPIFixture()
            let signer = try await fixture.pair()
            let imports = fixture.recordImports()
            let victim = fixture.stagingRoot.deletingLastPathComponent()
                .appendingPathComponent("victim-\(UUID().uuidString)")
            try Data("keep".utf8).write(to: victim)
            defer { try? FileManager.default.removeItem(at: victim) }
            let taken = fixture.stagingRoot.appendingPathComponent("taken", isDirectory: true)
            try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
            let target = taken.appendingPathComponent("meeting.m4a")
            if makeLink {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: victim)
            } else {
                try Data("keep".utf8).write(to: target)
            }
            fixture.makeStagingDirectory = { _ in taken }

            let response = await fixture.sendImport(signer, name: "meeting.m4a", body: Data("upload".utf8))

            #expect(response.status != 202)
            #expect(try Data(contentsOf: victim) == Data("keep".utf8))
            #expect(imports.count == 0)
        }
    }

    // MARK: - Failures remove the staged directory

    @Test("A body that does not match its signed hash is refused and its staged directory removed")
    func hashMismatch() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let signed = Data("signed bytes".utf8)
        let sent = Data("other bytes!".utf8)

        let response = await fixture.send(
            fixture.importHead(signer, signedBody: signed, fileNameHeader: "meeting.m4a"),
            body: sent
        )

        #expect(response.status == 401)
        #expect(errorCode(response) == "bad_signature")
        #expect(fixture.staged.isEmpty)
        #expect(imports.count == 0)
    }

    @Test("A client revoked during the upload gets unauthorized and its staged directory is removed")
    func revokedDuringUpload() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let body = Data("audio".utf8)
        let head = fixture.importHead(signer, signedBody: body, fileNameHeader: "meeting.m4a")

        guard case .admittedToFile(let upload) = await fixture.handler.admit(head, peer: fixture.peer) else {
            Issue.record("Expected admission to a staged file")
            return
        }
        upload.write(body)
        fixture.store.revoke(signer.clientID)
        upload.finishWriting()
        let response = await fixture.handler.handleUpload(head, upload: upload, peer: fixture.peer)

        #expect(response.status == 401)
        #expect(errorCode(response) == "unauthorized")
        #expect(fixture.staged.isEmpty)
        #expect(imports.count == 0)
    }

    @Test(
        "An import the app refuses answers its code and removes the staged directory",
        arguments: [
            (SingleAudioImportError.notAudio, 415, "not_audio"),
            (SingleAudioImportError.workspaceUnavailable, 503, "workspace_unavailable"),
            (SingleAudioImportError.notRecorded, 500, "import_not_recorded"),
        ]
    )
    func importRefused(error: SingleAudioImportError, status: Int, code: String) async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        fixture.importer = { _, _ throws(SingleAudioImportError) in throw error }

        let response = await fixture.sendImport(signer)

        #expect(response.status == status)
        #expect(errorCode(response) == code)
        #expect(fixture.staged.isEmpty)
    }
}

// MARK: - Over the socket

@MainActor
@Suite(.serialized)
struct ExtensionAPIImportStreamingTests {
    private func rawRequest(_ head: HTTPRequestHead) -> String {
        var text = "\(head.method) \(head.target) HTTP/1.1\r\n"
        for header in head.headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        return text + "Content-Length: \(head.contentLength)\r\n\r\n"
    }

    @Test("An upload sent in pieces over the socket reaches the importer whole")
    func streamed() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let listener = ExtensionAPIListener(handler: fixture.handler)
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let body = String(repeating: "0123456789", count: 20_000)
        let head = fixture.importHead(signer, signedBody: Data(body.utf8), fileNameHeader: "meeting.m4a")

        let client = try LoopbackClient(port: port)
        client.send(rawRequest(head))
        client.send(String(body.prefix(70_000)))
        client.send(String(body.dropFirst(70_000)))
        nonisolated(unsafe) let reader = client
        let response = await Task.detached { reader.readToEnd(timeout: 10) }.value

        let text = response.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(text.hasPrefix("HTTP/1.1 202 "))
        #expect(imports.contents == Data(body.utf8))
    }

    @Test("A client that disconnects mid-upload leaves nothing staged")
    func disconnectMidUpload() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let listener = ExtensionAPIListener(handler: fixture.handler)
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let body = String(repeating: "x", count: 10_000)
        let head = fixture.importHead(signer, signedBody: Data(body.utf8), fileNameHeader: "meeting.m4a")

        var client: LoopbackClient? = try LoopbackClient(port: port)
        client?.send(rawRequest(head))
        client?.send(String(body.prefix(4000)))
        #expect(await eventually { fixture.staged.count == 1 })
        client = nil

        #expect(await eventually { fixture.staged.isEmpty })
        #expect(imports.count == 0)
    }

    @Test("An upload that stops arriving is cut off and leaves nothing staged")
    func stalledUpload() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let imports = fixture.recordImports()
        let listener = ExtensionAPIListener(
            handler: fixture.handler,
            limits: .init(maximumConnections: 4, headDeadline: .seconds(10), bodyGap: .milliseconds(300))
        )
        let port = try await listener.start(port: 0)
        defer { listener.stop() }
        let body = String(repeating: "x", count: 10_000)
        let head = fixture.importHead(signer, signedBody: Data(body.utf8), fileNameHeader: "meeting.m4a")

        let client = try LoopbackClient(port: port)
        client.send(rawRequest(head))
        client.send(String(body.prefix(4000)))

        #expect(await eventually { fixture.staged.isEmpty && client.read(timeout: 0.05) == .closed })
        #expect(imports.count == 0)
    }
}

// MARK: - The app's single-file import

@MainActor
final class SingleAudioImportTests {
    private let workspaceRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SingleAudioImportTests-\(UUID().uuidString)", isDirectory: true)
    private let workspaceService = MockWorkspaceService()
    private let container: ModelContainer
    private let context: ModelContext

    init() throws {
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
        workspaceService.requireWritableResult = .success(Workspace(rootURL: workspaceRootURL))
        container = try ModelContainer(
            for: RecordingSession.self, ImportedSession.self, RecordingTranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    deinit {
        try? FileManager.default.removeItem(at: workspaceRootURL)
    }

    private enum Failure: Error {
        case failed
    }

    private func makeViewModel(
        probeAudio: AudioImportService.ProbeAudio? = nil,
        retranscribe: AudioImportService.Retranscribe? = nil,
        saveContext: AudioImportService.SaveContext? = nil
    ) -> JobsViewModel {
        let retranscriptionService = RetranscriptionService(transcriptionService: TranscriptionService())
        let service = AudioImportService(
            retranscriptionService: retranscriptionService,
            probeAudio: probeAudio ?? { url in
                AudioImportProbeResult(
                    title: url.deletingPathExtension().lastPathComponent,
                    originalFileName: url.lastPathComponent,
                    originalFormat: url.pathExtension,
                    duration: 1
                )
            },
            readChannelSamples: { _ in DecodedAudio(channels: [[0.1]], sampleRate: 48_000) },
            writeMonoAAC: { _, _ in },
            retranscribe: retranscribe ?? { _, _, _, _ in },
            saveContext: saveContext
        )
        return JobsViewModel(
            workspaceService: workspaceService,
            transcriptionService: MockTranscriptionService(),
            retranscriptionService: retranscriptionService,
            audioImportService: service
        )
    }

    private func file(_ name: String) throws -> URL {
        let url = workspaceRootURL.appendingPathComponent(name)
        try Data("bytes".utf8).write(to: url)
        return url
    }

    private func sessions() throws -> [ImportedSession] {
        try ModelContext(container).fetch(FetchDescriptor<ImportedSession>())
    }

    /// Set from conversion's end; read on the test's actor.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    @Test("A file that is not audio gives not_audio and saves no session")
    func notAudio() async throws {
        let viewModel = makeViewModel()
        let url = try file("notes.txt")

        await #expect(throws: SingleAudioImportError.notAudio) {
            try await viewModel.importAudioFile(at: url, context: context, conversionEnded: {})
        }
        #expect(try sessions().isEmpty)
    }

    @Test("No authorized workspace gives workspace_unavailable")
    func workspaceUnavailable() async throws {
        workspaceService.requireWritableResult = .failure(.notConfigured)
        let viewModel = makeViewModel()
        let url = try file("meeting.m4a")

        await #expect(throws: SingleAudioImportError.workspaceUnavailable) {
            try await viewModel.importAudioFile(at: url, context: context, conversionEnded: {})
        }
    }

    @Test("A session that cannot be saved gives import_not_recorded")
    func notRecorded() async throws {
        let viewModel = makeViewModel(saveContext: { _ in throw Failure.failed })
        let url = try file("meeting.m4a")

        await #expect(throws: SingleAudioImportError.notRecorded) {
            try await viewModel.importAudioFile(at: url, context: context, conversionEnded: {})
        }
    }

    @Test("The new session's id is returned, and conversion ends before transcription starts")
    func recorded() async throws {
        let ended = Flag()
        let endedBeforeTranscription = Flag()
        let viewModel = makeViewModel(retranscribe: { _, _, _, _ in
            if ended.value { endedBeforeTranscription.set() }
        })
        let url = try file("meeting.m4a")

        let id = try await viewModel.importAudioFile(at: url, context: context, conversionEnded: { ended.set() })

        #expect(try sessions().map(\.id) == [id])
        #expect(await eventually { endedBeforeTranscription.value })
    }

    @Test("A file that passes the type check but fails conversion yields a session with error status, titled from its name")
    func conversionFails() async throws {
        let ended = Flag()
        let viewModel = makeViewModel(probeAudio: { _ in throw Failure.failed })
        let url = try file("Café meeting.m4a")

        let id = try await viewModel.importAudioFile(at: url, context: context, conversionEnded: { ended.set() })

        #expect(await eventually { ended.value })
        let session = try #require(try sessions().first { $0.id == id })
        #expect(session.title == "Café meeting")
        guard case .error = session.status else {
            Issue.record("Expected error status, got \(session.status)")
            return
        }
    }

    @Test("Over the API, a session's title comes from the uploaded name and the staged directory goes once conversion fails")
    func overTheAPI() async throws {
        let fixture = ExtensionAPIFixture()
        let signer = try await fixture.pair()
        let viewModel = makeViewModel(probeAudio: { _ in throw Failure.failed })
        let context = context
        fixture.importer = { url, conversionEnded throws(SingleAudioImportError) in
            try await viewModel.importAudioFile(at: url, context: context, conversionEnded: conversionEnded)
        }

        let response = await fixture.sendImport(signer, name: "Café meeting.m4a")

        #expect(response.status == 202)
        let body = try JSONDecoder().decode(SessionIDBody.self, from: response.body)
        #expect(await eventually { fixture.staged.isEmpty })
        let session = try #require(try sessions().first { "imported:\($0.id.uuidString)" == body.sessionId })
        #expect(session.title == "Café meeting")
    }
}
