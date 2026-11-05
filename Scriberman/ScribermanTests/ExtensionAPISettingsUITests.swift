import Foundation
import Network
import Testing
@testable import Scriberman

/// The Settings section's model and the pairing prompt, through their public surface.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ExtensionAPISettingsUITests {
    private let defaults = UserDefaults(suiteName: "ExtensionAPISettingsUITests-\(UUID().uuidString)")!
    private let keychain = MockKeychainStore()

    private final class StateBox {
        var state = ExtensionAPIService.State.stopped
    }

    private func makeModel(state: StateBox = StateBox()) -> (ExtensionAPISettingsViewModel, ExtensionAPISettings, ExtensionAPIPairingStore) {
        let settings = ExtensionAPISettings(userDefaults: defaults)
        let store = ExtensionAPIPairingStore(defaults: defaults, keychain: keychain)
        let model = ExtensionAPISettingsViewModel(
            settings: settings,
            pairingStore: store,
            state: { state.state },
            dateText: { _ in "DATE" }
        )
        return (model, settings, store)
    }

    // MARK: - Toggle and port

    @Test("The toggle turns the API setting on and off")
    func toggle() {
        let (model, settings, _) = makeModel()
        #expect(!model.isEnabled)
        model.isEnabled = true
        #expect(settings.isEnabled)
        model.isEnabled = false
        #expect(!settings.isEnabled)
    }

    @Test("The port field shows the configured port")
    func portShown() throws {
        let (model, _, _) = makeModel()
        #expect(model.portText == String(ExtensionAPISettings.defaultPort))
    }

    @Test("A valid port is saved and clears the error")
    func validPort() throws {
        let (model, settings, _) = makeModel()
        model.portText = "50000"
        model.commitPort()
        #expect(settings.port == 50000)
        #expect(model.portError == nil)
    }

    @Test("An invalid port keeps the old one and shows the range error", arguments: ["80", "70000", "abc", ""])
    func invalidPort(text: String) throws {
        let (model, settings, _) = makeModel()
        model.portText = text
        model.commitPort()
        #expect(settings.port == ExtensionAPISettings.defaultPort)
        #expect(model.portError == ExtensionAPIStrings.portInvalid(
            min: ExtensionAPISettings.validPorts.lowerBound,
            max: ExtensionAPISettings.validPorts.upperBound
        ))
    }

    @Test("A valid port after an invalid one clears the error")
    func errorClears() throws {
        let (model, _, _) = makeModel()
        model.portText = "1"
        model.commitPort()
        model.portText = "2000"
        model.commitPort()
        #expect(model.portError == nil)
    }

    // MARK: - Status

    @Test("Off, starting and listening each have their status line")
    func statusLines() {
        let box = StateBox()
        let (model, _, _) = makeModel(state: box)
        #expect(model.status == .init(text: ExtensionAPIStrings.off, isFailure: false))

        model.isEnabled = true
        #expect(model.status == .init(text: ExtensionAPIStrings.starting, isFailure: false))

        box.state = .listening(port: 47615)
        #expect(model.status == .init(text: ExtensionAPIStrings.listening(port: 47615), isFailure: false))
    }

    @Test("A port taken by another program is shown as a failure naming the port")
    func portInUse() {
        let box = StateBox()
        box.state = .failed(.init(port: 4000, error: .posix(.EADDRINUSE)))
        let (model, _, _) = makeModel(state: box)
        model.isEnabled = true
        #expect(model.status == .init(text: ExtensionAPIStrings.portInUse(port: 4000), isFailure: true))
    }

    @Test("Another bind failure is shown with the system's description")
    func otherBindFailure() {
        let box = StateBox()
        let error = NWError.posix(.EACCES)
        box.state = .failed(.init(port: 4000, error: error))
        let (model, _, _) = makeModel(state: box)
        model.isEnabled = true
        #expect(model.status == .init(
            text: ExtensionAPIStrings.bindFailed(port: 4000, detail: error.localizedDescription),
            isFailure: true
        ))
    }

    // MARK: - Paired clients

    @Test("Paired clients are listed with their name, verified identifier and team")
    func clientsListed() throws {
        let (model, _, store) = makeModel()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let client = try store.pair(
            name: "Tinycast",
            callerIdentity: .init(designatedRequirement: "dr", signingIdentifier: "com.example.tinycast", teamIdentifier: "J656U8XZ93"),
            at: date
        ).client

        #expect(model.clients == [.init(
            id: client.id,
            name: "Tinycast",
            pairedText: ExtensionAPIStrings.pairedOn("DATE"),
            signingIdentifier: "com.example.tinycast",
            teamText: "J656U8XZ93",
            needsPairingAgain: false
        )])
    }

    @Test("A client whose signature has no team shows the no-team text")
    func noTeam() throws {
        let (model, _, store) = makeModel()
        _ = try store.pair(name: "Tool", callerIdentity: .init(designatedRequirement: "dr", signingIdentifier: "tool"), at: .now)
        #expect(model.clients.map(\.teamText) == [ExtensionAPIStrings.noTeam])
    }

    @Test("A client paired without a recorded requirement is marked to pair again")
    func pairAgain() throws {
        let (model, _, store) = makeModel()
        _ = try store.pair(name: "Old", callerIdentity: .init(designatedRequirement: nil), at: .now)
        #expect(model.clients.map(\.needsPairingAgain) == [true])
    }

    @Test("Revoking removes the client from the list, the store and the Keychain")
    func revoke() throws {
        let (model, _, store) = makeModel()
        let kept = try store.pair(name: "Kept", callerIdentity: .init(designatedRequirement: "a"), at: .now).client
        let removed = try store.pair(name: "Removed", callerIdentity: .init(designatedRequirement: "b"), at: .now).client

        model.revoke(removed.id)

        #expect(model.clients.map(\.id) == [kept.id])
        #expect(store.clients.map(\.id) == [kept.id])
        #expect(store.credentials(for: removed.id) == nil)
        #expect(keychain.storage.count == 1)
    }

    // MARK: - Pairing prompt

    private func request(_ identity: ExtensionAPICallerIdentity = .init(designatedRequirement: "dr")) -> ExtensionAPIPairingRequest {
        ExtensionAPIPairingRequest(id: UUID(), claimedName: "Tinycast", callerIdentity: identity)
    }

    @Test("Approving the shown request reports approve once and hides the prompt")
    func approveOnce() {
        let prompter = ExtensionAPIPairingPrompter()
        var decisions: [ExtensionAPIPairingDecision] = []
        prompter.present(request()) { decisions.append($0) }
        #expect(prompter.current != nil)

        prompter.approve()
        prompter.approve()
        prompter.deny()

        #expect(decisions == [.approve])
        #expect(prompter.current == nil)
    }

    @Test("Denying the shown request reports deny and hides the prompt")
    func denyOnce() {
        let prompter = ExtensionAPIPairingPrompter()
        var decisions: [ExtensionAPIPairingDecision] = []
        prompter.present(request()) { decisions.append($0) }
        prompter.deny()
        #expect(decisions == [.deny])
        #expect(prompter.current == nil)
    }

    @Test("A withdrawn request is hidden and can no longer be answered")
    func withdrawn() {
        let prompter = ExtensionAPIPairingPrompter()
        var decisions: [ExtensionAPIPairingDecision] = []
        let shown = request()
        prompter.present(shown) { decisions.append($0) }
        prompter.withdraw(shown)
        prompter.approve()
        #expect(prompter.current == nil)
        #expect(decisions.isEmpty)
    }

    @Test("Withdrawing a request that is not shown leaves the shown one")
    func withdrawOther() {
        let prompter = ExtensionAPIPairingPrompter()
        let shown = request()
        prompter.present(shown) { _ in }
        prompter.withdraw(request())
        #expect(prompter.current == shown)
    }

    @Test("Showing and hiding the prompt are reported to the panel")
    func panelUpdates() {
        let prompter = ExtensionAPIPairingPrompter()
        var shown: [ExtensionAPIPairingRequest?] = []
        prompter.onChange = { shown.append($0) }
        let first = request()
        prompter.present(first) { _ in }
        prompter.approve()
        #expect(shown == [first, nil])
    }

    @Test("The prompt shows the claimed name, the verified identifier and team")
    func promptContent() {
        let content = ExtensionAPIPairingPromptContent(request(.init(
            designatedRequirement: "dr", signingIdentifier: "com.example.tinycast", teamIdentifier: "J656U8XZ93"
        )))
        #expect(content.claimedNameText == ExtensionAPIStrings.claimedName("Tinycast"))
        #expect(content.signingIdentifier == "com.example.tinycast")
        #expect(content.teamText == "J656U8XZ93")
    }

    @Test("The prompt shows the no-team text for a caller without a team")
    func promptNoTeam() {
        let content = ExtensionAPIPairingPromptContent(request(.init(designatedRequirement: "dr", signingIdentifier: "tool")))
        #expect(content.teamText == ExtensionAPIStrings.noTeam)
    }

    // MARK: - Through the handler

    @Test("The handler passes the verified identity to the prompt")
    func identityReachesPrompt() async throws {
        let fixture = ExtensionAPIFixture()
        let identity = ExtensionAPICallerIdentity(designatedRequirement: "dr", signingIdentifier: "com.example.tinycast", teamIdentifier: "J656U8XZ93")
        fixture.verifier.pairingIdentity = identity
        _ = try await fixture.pair()
        #expect(fixture.presenter.presented.map(\.callerIdentity) == [identity])
    }

    @Test("Approving in the prompt pairs the client")
    func approveThroughHandler() async throws {
        let fixture = ExtensionAPIFixture()
        let prompter = ExtensionAPIPairingPrompter()
        fixture.handler.pairingPresenter = prompter
        let task = fixture.startPairing()
        while prompter.current == nil { await Task.yield() }
        prompter.approve()
        let response = await task.value
        #expect(response.status == 200)
        #expect(fixture.store.clients.count == 1)
    }

    @Test("Denying in the prompt answers pairing_denied")
    func denyThroughHandler() async throws {
        let fixture = ExtensionAPIFixture()
        let prompter = ExtensionAPIPairingPrompter()
        fixture.handler.pairingPresenter = prompter
        let task = fixture.startPairing()
        while prompter.current == nil { await Task.yield() }
        prompter.deny()
        let response = await task.value
        #expect(errorCode(response) == "pairing_denied")
        #expect(fixture.store.clients.isEmpty)
    }

    @Test("An expired pairing hides the prompt")
    func expiryHides() async throws {
        let fixture = ExtensionAPIFixture()
        let prompter = ExtensionAPIPairingPrompter()
        fixture.handler.pairingPresenter = prompter
        let task = fixture.startPairing()
        while prompter.current == nil { await Task.yield() }
        await fixture.expiry.fire()
        _ = await task.value
        #expect(prompter.current == nil)
    }

    @Test("A client that disconnects hides the prompt")
    func disconnectHides() async throws {
        let fixture = ExtensionAPIFixture()
        let prompter = ExtensionAPIPairingPrompter()
        fixture.handler.pairingPresenter = prompter
        let task = fixture.startPairing()
        while prompter.current == nil { await Task.yield() }
        task.cancel()
        _ = await task.value
        #expect(prompter.current == nil)
    }

    // MARK: - Error messages

    @Test("Every error code is sent with its message", arguments: ExtensionAPIErrorCode.allCases)
    func errorMessages(code: ExtensionAPIErrorCode) throws {
        let response = ExtensionAPIHandler.error(code, status: 400)
        let body = try JSONDecoder().decode(ExtensionAPIErrorBody.self, from: response.body)
        #expect(body == ExtensionAPIErrorBody(code: code.rawValue, message: code.message))
        #expect(!code.message.isEmpty)
        #expect(code.message != code.rawValue)
    }
}
