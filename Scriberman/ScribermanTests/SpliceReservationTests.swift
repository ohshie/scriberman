import Combine
import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpliceReservationTests {
    @Test(arguments: [false, true])
    func pausedExportRefusesChangesToEveryMember(holdSibling: Bool) async throws {
        let f = try SpliceFixture()
        let registry = SpliceReservations()
        var initial = f.plan()
        initial.cuts = [75]
        initial.parts = [.init(title: "First two"), .init(title: "Third")]
        let parts = try await SpliceService(capacityProvider: { _ in .max }, export: SpliceFixture.fakeExport, reservations: registry)
            .splice(session: f.session, plan: initial, workspace: f.workspace, context: f.context)
        let groupID = try #require(f.session.spliceGroupID)
        let coordinator = SessionDeletionCoordinator(workspaceService: ReconciliationWorkspace(workspace: f.workspace),
            announce: { _ in }, startAccess: { _ in false }, stopAccess: { _ in },
            scheduleExpiry: { _, _ in AnyCancellable {} }, spliceReservations: registry)
        if holdSibling { #expect(await coordinator.delete(parts[1], context: f.context, undoManager: nil) == .deleted) }
        let members = holdSibling ? [f.session] : parts
        let before = members.map(RecordingSessionRecord.init)
        let retranscriber = RetranscriptionService(transcriptionService: TranscriptionService(), spliceReservations: registry)
        let jobs = JobsViewModel(workspaceService: ReconciliationWorkspace(workspace: f.workspace),
            transcriptionService: MockTranscriptionService(), retranscriptionService: retranscriber,
            audioImportService: AudioImportService(retranscriptionService: retranscriber), spliceReservations: registry)
        let api = ExtensionAPIFixture()
        api.spliceReservations = registry
        api.transformationContext = f.context
        api.sessionContext = f.context
        let prompt = AIPrompt(name: "Summary", content: "Summarize")
        api.prompts = [prompt]
        let signer = try await api.pair()
        api.handler.sessionActions = ExtensionAPISessionActions(
            requestSession: { _ in Issue.record("Reserved session opened") },
            showWindow: { Issue.record("Reserved session action showed a window") },
            export: { _, _ in Issue.record("Reserved session exported"); return .cancelled },
            authorizedWorkspace: { () throws(WorkspaceError) in f.workspace },
            revealInFinder: { _ in Issue.record("Reserved session revealed") })
        let gate = PausedSpliceGate()
        let service = SpliceService(capacityProvider: { _ in .max }, export: { from, to, start, end in
            await gate.pauseOnce()
            try await SpliceFixture.fakeExport(from, to, start, end)
        }, reservations: registry)
        let task = Task { _ = try await service.splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context) }
        await gate.waitUntilPaused()
        defer { gate.release() }
        #expect(registry.hasReservations)
        for member in members {
            #expect(registry.isReserved(sessionID: member.id))
            #expect(await coordinator.delete(member, context: f.context, undoManager: nil) == .busy)
            jobs.reprocess(session: member, context: f.context)
            await retranscriber.retranscribe(sessionID: member.id, modelContainer: f.container, workspace: f.workspace)
            #expect(throws: AITransformationRunner.StartRefusal.busy) { try api.runner.start(prompt: prompt, on: member) }
            let id = "recording:\(member.id.uuidString)"
            let response = await api.sendSigned(signer, "POST", "/v1/sessions/\(id)/transformations",
                body: try JSONEncoder().encode(["promptId": prompt.id.uuidString]))
            #expect(response.status == 409)
            #expect(errorCode(response) == "session_busy")
            #expect(try JSONDecoder().decode(ExtensionAPIErrorBody.self, from: response.body).message == SpliceCopy.errorMessage(SpliceError.busy))
            for action in ["", "/open", "/export", "/reveal"] {
                let response = await api.sendSigned(signer, action.isEmpty ? "GET" : "POST", "/v1/sessions/\(id)\(action)")
                #expect(response.status == 409)
                #expect(errorCode(response) == "session_busy")
            }
            await #expect(throws: SpliceError.busy) {
                _ = try await SpliceService(reservations: registry).restore(session: member, workspace: f.workspace,
                    context: f.context, coordinator: coordinator)
            }
            let availability = SessionCommandAvailability(selection: .recording(.done),
                isRecordingRunning: false, isTranscriptShown: true, hasLoadedAudio: true, hasFindTarget: true,
                isSelectionInActiveWorkspace: true, hasSpliceCutPoint: true, hasSpliceGroup: true,
                isSessionReserved: registry.isReserved(member))
            #expect(SessionCommandAvailability.sessionMenuCommands.allSatisfy { !availability.isEnabled($0) })
        }
        await #expect(throws: SpliceError.busy) {
            _ = try await SpliceService(capacityProvider: { _ in .max }, export: SpliceFixture.fakeExport, reservations: registry)
                .splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        }
        if holdSibling {
            #expect(!registry.isReserved(sessionID: parts[1].id))
            #expect(await coordinator.restoreHeld(parts[1].id, context: f.context) == false)
            #expect(await coordinator.removeHeld(parts[1].id, context: f.context) == .busy)
        }
        #expect(members.map(RecordingSessionRecord.init) == before)
        #expect(!jobs.isRetranscribing)
        gate.release()
        _ = try await task.value
        #expect(!registry.hasReservations)
        #expect(members.allSatisfy { !registry.isReserved($0) })
        #expect(!api.runner.isRunning(f.session.id))
        #expect(registry.isReserved(sessionID: UUID(), groupID: groupID) == false)
    }

    @Test(arguments: ["export", "save", "cancel"])
    func reservationIsReleasedOnFailure(path: String) async throws {
        let f = try SpliceFixture()
        let registry = SpliceReservations()
        let gate = PausedSpliceGate()
        let service = SpliceService(capacityProvider: { _ in .max }, export: { from, to, start, end in
            await gate.pauseOnce()
            if path == "export" { throw CocoaError(.fileWriteUnknown) }
            try await SpliceFixture.fakeExport(from, to, start, end)
        }, saveContext: { context in
            if path == "save" { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        }, reservations: registry)
        let task = Task { _ = try await service.splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context) }
        await gate.waitUntilPaused()
        #expect(registry.isReserved(f.session))
        if path == "cancel" { task.cancel() }
        gate.release()
        do { _ = try await task.value; Issue.record("Expected failure") }
        catch { #expect(path != "cancel" || error is CancellationError) }
        #expect(!registry.hasReservations)
        #expect(f.session.spliceGroupID == nil)
        #expect(f.session.duration == 120)
        #expect(try Data(contentsOf: f.audioURL) == SpliceFixture.audio)
    }

    @Test
    func titleSpeakerAndTagChangesRefuseAReservation() throws {
        let f = try SpliceFixture()
        let registry = SpliceReservations.shared
        let groupID = UUID()
        try registry.reserve(sessionID: f.session.id, groupID: groupID)
        defer { registry.release(sessionID: f.session.id, groupID: groupID) }
        let before = RecordingSessionRecord(f.session)
        #expect(TranscriptDetailViewModel.saveTitle("Changed", of: f.session, context: f.context)
            == .saveFailed(SpliceCopy.errorMessage(SpliceError.busy)))
        #expect(TranscriptDetailViewModel.renameSpeaker(id: "A", to: "Changed", in: f.session.transcript!, of: f.session) == nil)
        let tag = RecordingTag(name: "Other", colorHex: "112233")
        f.context.insert(tag)
        #expect(throws: SpliceError.busy) { try TagService().assign(tag, to: f.session, in: f.context) }
        #expect(throws: SpliceError.busy) { try TagService().unassign(f.session.tags[0], from: f.session, in: f.context) }
        #expect(RecordingSessionRecord(f.session) == before)
    }

    @Test(arguments: ["success", "move", "cancel"])
    func restoreReservesBeforeAuthorizationAndKeepsOwnershipThroughMemberDeletes(path: String) async throws {
        let f = try SpliceFixture()
        let registry = SpliceReservations()
        let parts = try await SpliceService(capacityProvider: { _ in .max }, export: SpliceFixture.fakeExport, reservations: registry)
            .splice(session: f.session, plan: f.plan(), workspace: f.workspace, context: f.context)
        let memberIDs = parts.map(\.id)
        let gate = PausedSpliceGate()
        let coordinator = SessionDeletionCoordinator(workspaceService: PausedReservationWorkspace(workspace: f.workspace, gate: gate),
            announce: { _ in }, startAccess: { _ in false }, stopAccess: { _ in },
            scheduleExpiry: { _, _ in AnyCancellable {} }, spliceReservations: registry)
        var files = SpliceFileOperations()
        if path == "move" { files.move = { _, _ in throw CocoaError(.fileWriteUnknown) } }
        files.checkpoint = { _ in #expect(memberIDs.allSatisfy { registry.isReserved(sessionID: $0) }) }
        let service = SpliceService(files: files, reservations: registry)
        let task = Task { try await service.restore(session: f.session, workspace: f.workspace, context: f.context, coordinator: coordinator) }
        await gate.waitUntilPaused()
        #expect(parts.allSatisfy { registry.isReserved(sessionID: $0.id) })
        for part in parts { #expect(await coordinator.delete(part, context: f.context, undoManager: nil) == .busy) }
        if path == "cancel" { task.cancel() }
        gate.release()
        do {
            let result = try await task.value
            #expect(path == "success")
            #expect(result == SpliceService.RestoreResult())
            #expect(try f.context.fetch(FetchDescriptor<RecordingSession>()).map(\.id) == [f.session.id])
            #expect(try HoldingFolder(workspace: f.workspace).snapshotsForMembership().count == 2)
        } catch { #expect(path != "success") }
        #expect(!registry.hasReservations)
    }

    @Test
    func registryRejectsOverlappingGroupsAndSessionsAndReleasesOnlyItsOwnLease() throws {
        let registry = SpliceReservations()
        let first = UUID(), second = UUID(), group = UUID()
        let reservation = try registry.reserve(sessionIDs: [first, second], groupID: group)
        #expect(throws: SpliceError.busy) { try registry.reserve(sessionIDs: [UUID()], groupID: group) }
        #expect(throws: SpliceError.busy) { try registry.reserve(sessionIDs: [second], groupID: UUID()) }
        registry.release(reservation)
        let replacement = try registry.reserve(sessionIDs: [first, second], groupID: group)
        registry.release(reservation)
        #expect(registry.isReserved(sessionID: second))
        #expect(!registry.permits(reservation, sessionID: first))
        #expect(registry.permits(replacement, sessionID: second))
        registry.release(replacement)
        #expect(!registry.hasReservations)
    }
}

private struct PausedReservationWorkspace: WorkspaceServiceProtocol {
    let workspace: Workspace
    let gate: PausedSpliceGate
    func currentWorkspace() async -> Workspace? { await gate.pauseOnce(); return workspace }
    func requireAuthorizedWorkspace() async throws(WorkspaceError) -> Workspace { workspace }
}

@MainActor
final class PausedSpliceGate {
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        guard !paused else { return }
        paused = true
        await withCheckedContinuation {
            continuation = $0
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
