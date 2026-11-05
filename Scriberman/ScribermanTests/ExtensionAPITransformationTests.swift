import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// Running a saved prompt on a session through the API and reading the run back as an operation.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExtensionAPITransformationTests {
    private struct Started: Decodable {
        let operationId: String
    }

    private struct Operation: Decodable, Equatable {
        let state: String
        var transformationId: String?
        var code: String?
        var message: String?
    }

    private struct ProviderDown: LocalizedError {
        var errorDescription: String? { "provider-down-7f3a" }
    }

    private let fixture = ExtensionAPIFixture()
    private let prompt = AIPrompt(name: "Summary", content: "Summarize")

    init() {
        fixture.prompts = [prompt]
        fixture.aiService.isEnabled = true
        fixture.aiService.isConfigured = true
        fixture.aiService.selectedModelID = "model-a"
        fixture.aiService.transformationResult = "Result text"
    }

    // MARK: - Fixtures

    private func makeRecording(transcriptText: String? = "Transcript") throws -> RecordingSession {
        let session = RecordingSession(
            createdAt: Date(timeIntervalSince1970: 0),
            duration: 10,
            micAudioURL: "/tmp/mic.wav",
            mixdownURL: "/tmp/mix.m4a",
            title: "Session",
            status: .done
        )
        if let transcriptText {
            session.transcript = Self.transcript(transcriptText)
        }
        fixture.container.mainContext.insert(session)
        try fixture.container.mainContext.save()
        return session
    }

    private func makeImported() throws -> ImportedSession {
        let session = ImportedSession(
            duration: 10,
            title: "Imported",
            originalFileName: "call.m4a",
            originalFormat: "m4a",
            status: .done
        )
        session.transcript = Self.transcript("Imported transcript")
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

    private func body(promptID: String) -> Data {
        try! JSONEncoder().encode(["promptId": promptID])
    }

    private func run(
        _ signer: ExtensionAPITestSigner,
        on sessionID: String,
        promptID: String? = nil
    ) async -> HTTPResponse {
        await fixture.sendSigned(
            signer,
            "POST",
            "/v1/sessions/\(sessionID)/transformations",
            body: body(promptID: promptID ?? prompt.id.uuidString)
        )
    }

    private func operation(_ signer: ExtensionAPITestSigner, _ operationID: String) async throws -> Operation {
        let response = await fixture.sendSigned(signer, "GET", "/v1/operations/\(operationID)")
        try #require(response.status == 200)
        return try JSONDecoder().decode(Operation.self, from: response.body)
    }

    private func started(_ response: HTTPResponse) throws -> String {
        try #require(response.status == 202)
        return try JSONDecoder().decode(Started.self, from: response.body).operationId
    }

    /// Waits until the run with `operationID` has ended.
    private func waitForEnd(of operationID: String) async throws {
        _ = await fixture.runner.completion(of: try #require(UUID(uuidString: operationID)))
    }

    /// Holds every provider call until `release` runs or the call is cancelled; `isHeld` turns
    /// true once a call waits.
    private func holdRuns() -> (isHeld: () -> Bool, release: () -> Void) {
        final class Hold {
            var waiting = false
            var released = false
        }
        let hold = Hold()
        fixture.aiService.transformationGate = {
            hold.waiting = true
            while !hold.released, !Task.isCancelled {
                await Task.yield()
            }
        }
        return ({ hold.waiting }, { hold.released = true })
    }

    /// The session's history as another context reads it from the store.
    private func savedHistory(of sessionID: UUID) throws -> [AITransformation] {
        let reader = ModelContext(fixture.container)
        let descriptor = FetchDescriptor<RecordingSession>(predicate: #Predicate { $0.id == sessionID })
        return try reader.fetch(descriptor).first?.aiTransformations ?? []
    }

    // MARK: - Success

    @Test("A run answers 202 with an operation id and succeeds with the saved transformation's id")
    func success() async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()

        let operationID = try started(await run(signer, on: "recording:\(session.id.uuidString)"))
        try await waitForEnd(of: operationID)

        let history = try savedHistory(of: session.id)
        let saved = try #require(history.first)
        #expect(history.count == 1)
        #expect(saved.resultText == "Result text")
        #expect(try await operation(signer, operationID) == Operation(
            state: "succeeded",
            transformationId: saved.id.uuidString
        ))
    }

    @Test("A run on an imported session saves to that session")
    func importedSession() async throws {
        let session = try makeImported()
        let signer = try await fixture.pair()

        let operationID = try started(await run(signer, on: "imported:\(session.id.uuidString)"))
        try await waitForEnd(of: operationID)

        let reader = ModelContext(fixture.container)
        let sessionID = session.id
        let saved = try reader.fetch(FetchDescriptor<ImportedSession>(predicate: #Predicate { $0.id == sessionID }))
        let transformationID = try #require(saved.first?.aiTransformations.first?.id)
        #expect(try await operation(signer, operationID).transformationId == transformationID.uuidString)
    }

    @Test("An operation still under way reads as running")
    func running() async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()
        let hold = holdRuns()

        let operationID = try started(await run(signer, on: "recording:\(session.id.uuidString)"))
        while !hold.isHeld() {
            await Task.yield()
        }

        #expect(try await operation(signer, operationID) == Operation(state: "running"))
        hold.release()
        try await waitForEnd(of: operationID)
    }

    @Test("The response to a run is signed")
    func signed() async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()
        let nonce = ExtensionAPITestSigner.randomNonce()

        let response = await fixture.sendSigned(
            signer,
            "POST",
            "/v1/sessions/recording:\(session.id.uuidString)/transformations",
            body: body(promptID: prompt.id.uuidString),
            nonce: nonce
        )

        #expect(signer.verifies(response, nonce: nonce))
        try await waitForEnd(of: try started(response))
    }

    // MARK: - Refusals

    @Test("A second run on a session with a run under way is refused as transformation_running")
    func transformationRunning() async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()
        let hold = holdRuns()
        let first = try started(await run(signer, on: "recording:\(session.id.uuidString)"))
        while !hold.isHeld() {
            await Task.yield()
        }

        let second = await run(signer, on: "recording:\(session.id.uuidString)")

        #expect(second.status == 409)
        #expect(errorCode(second) == "transformation_running")
        hold.release()
        try await waitForEnd(of: first)
        #expect(try savedHistory(of: session.id).count == 1)
    }

    @Test("With AI not set up the run is refused as ai_not_configured")
    func aiNotConfigured() async throws {
        fixture.aiService.isEnabled = false
        let session = try makeRecording()
        let signer = try await fixture.pair()

        let response = await run(signer, on: "recording:\(session.id.uuidString)")

        #expect(response.status == 409)
        #expect(errorCode(response) == "ai_not_configured")
        #expect(fixture.aiService.performedTransformations.isEmpty)
    }

    @Test("A session without a transcript is refused as no_transcript")
    func noTranscript() async throws {
        let session = try makeRecording(transcriptText: nil)
        let signer = try await fixture.pair()

        let response = await run(signer, on: "recording:\(session.id.uuidString)")

        #expect(response.status == 409)
        #expect(errorCode(response) == "no_transcript")
        #expect(fixture.aiService.performedTransformations.isEmpty)
    }

    @Test("An unknown prompt id is not_found")
    func unknownPrompt() async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()

        let response = await run(signer, on: "recording:\(session.id.uuidString)", promptID: UUID().uuidString)

        #expect(response.status == 404)
        #expect(errorCode(response) == "not_found")
        #expect(fixture.aiService.performedTransformations.isEmpty)
    }

    @Test(
        "An unknown or malformed session id is not_found",
        arguments: ["recording:\(UUID().uuidString)", "imported:\(UUID().uuidString)", "recording:abc", "other:\(UUID().uuidString)", "abc"]
    )
    func unknownSession(sessionID: String) async throws {
        _ = try makeRecording()
        let signer = try await fixture.pair()

        let response = await run(signer, on: sessionID)

        #expect(response.status == 404)
        #expect(errorCode(response) == "not_found")
        #expect(fixture.aiService.performedTransformations.isEmpty)
    }

    @Test("A session id with the wrong kind is not_found")
    func wrongKind() async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()

        let response = await run(signer, on: "imported:\(session.id.uuidString)")

        #expect(response.status == 404)
        #expect(errorCode(response) == "not_found")
    }

    @Test("A body without a valid prompt id is invalid_request", arguments: ["", "{}", "{\"promptId\": 5}", "{\"promptId\": \"abc\"}"])
    func invalidBody(body: String) async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()

        let response = await fixture.sendSigned(
            signer,
            "POST",
            "/v1/sessions/recording:\(session.id.uuidString)/transformations",
            body: Data(body.utf8)
        )

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_request")
    }

    @Test("A client revoked while the request is suspended gets unauthorized and starts no run")
    func revokedDuringSuspension() async throws {
        let session = try makeRecording()
        let signer = try await fixture.pair()
        var release: CheckedContinuation<Void, Never>?
        fixture.promptsGate = {
            await withCheckedContinuation { release = $0 }
        }

        let task = Task { @MainActor in await run(signer, on: "recording:\(session.id.uuidString)") }
        while release == nil {
            await Task.yield()
        }
        fixture.store.revoke(signer.clientID)
        release?.resume()
        let response = await task.value

        #expect(errorCode(response) == "unauthorized")
        #expect(fixture.aiService.performedTransformations.isEmpty)
        #expect(fixture.runner.isRunning(session.id) == false)
    }

    // MARK: - Failures through the operation

    @Test("A provider failure is reported through the operation as failed with code and message")
    func providerFailure() async throws {
        fixture.aiService.transformationError = ProviderDown()
        let session = try makeRecording()
        let signer = try await fixture.pair()

        let operationID = try started(await run(signer, on: "recording:\(session.id.uuidString)"))
        try await waitForEnd(of: operationID)

        #expect(try await operation(signer, operationID) == Operation(
            state: "failed",
            code: "provider_failed",
            message: "provider-down-7f3a"
        ))
        #expect(try savedHistory(of: session.id).isEmpty)
    }

    @Test("A session deleted during the run fails the operation as not_found")
    func deletedDuringRun() async throws {
        let session = try makeRecording()
        let sessionID = session.id
        let signer = try await fixture.pair()
        let hold = holdRuns()
        let operationID = try started(await run(signer, on: "recording:\(sessionID.uuidString)"))
        while !hold.isHeld() {
            await Task.yield()
        }

        // A delete that is undone: the record stays, but the run started before it.
        await fixture.sessionJobs.startDeleting(sessionID)
        fixture.sessionJobs.finishDeleting(sessionID)
        hold.release()
        try await waitForEnd(of: operationID)

        let state = try await operation(signer, operationID)
        #expect(state.state == "failed")
        #expect(state.code == "not_found")
        #expect(try savedHistory(of: sessionID).isEmpty)
    }

    // MARK: - Operations

    @Test("An unknown or malformed operation id is not_found", arguments: [UUID().uuidString, "abc"])
    func unknownOperation(operationID: String) async throws {
        let signer = try await fixture.pair()

        let response = await fixture.sendSigned(signer, "GET", "/v1/operations/\(operationID)")

        #expect(response.status == 404)
        #expect(errorCode(response) == "not_found")
    }
}
