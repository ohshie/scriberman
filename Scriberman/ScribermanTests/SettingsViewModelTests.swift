import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
final class SettingsViewModelTests {
    private var tempRoots: [URL] = []

    deinit {
        let fileManager = FileManager.default
        for root in tempRoots {
            try? fileManager.removeItem(at: root)
        }
    }

    @Test
    func testDownloadAllTappedSuccessTransitionsToAllReady() async throws {
        let workspaceRoot = try makeTempRoot()
        let workspace = Workspace(rootURL: workspaceRoot)
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace

        let mockService = MockModelInstallService()
        await mockService.setCanInstallModels(true)

        let viewModel = SettingsViewModel(
            workspaceService: workspaceService,
            modelInstallService: mockService,
            speakerEmbeddingStore: try makeSpeakerEmbeddingStore()
        )
        viewModel.canDownloadModels = true

        let probe = BundlePhaseProbe()
        // A polling observer alone can miss the brief .warmingUp window under
        // parallel test load; capture the phase at the warm-up call itself.
        await mockService.setWarmUpHook { [viewModel] in
            await probe.record(viewModel.bundlePhase)
        }
        let observer = Task {
            while !Task.isCancelled {
                await probe.record(viewModel.bundlePhase)
                await Task.yield()
            }
        }

        await viewModel.downloadAllTapped()

        observer.cancel()
        _ = await observer.result

        let observed = await probe.snapshot()
        #expect(observed.contains { phase in
            if case .downloading = phase { return true }
            return false
        })
        #expect(observed.contains(.warmingUp))
        #expect(viewModel.bundlePhase == .allReady)

        let installOrder = await mockService.installOrder()
        #expect(installOrder == [.asrParakeetV3, .vadSilero, .offlineDiarization, .lseendDiarization])
        let warmedUp = await mockService.didWarmUp()
        #expect(warmedUp)
    }

    @Test
    func testDownloadAllTappedFailureTransitionsToError() async throws {
        let workspaceRoot = try makeTempRoot()
        let workspace = Workspace(rootURL: workspaceRoot)
        let workspaceService = MockWorkspaceService()
        workspaceService.currentWorkspaceResult = workspace

        let mockService = MockModelInstallService()
        await mockService.setCanInstallModels(true)
        await mockService.setFailureGroup(.vadSilero)

        let viewModel = SettingsViewModel(
            workspaceService: workspaceService,
            modelInstallService: mockService,
            speakerEmbeddingStore: try makeSpeakerEmbeddingStore()
        )
        viewModel.canDownloadModels = true

        await viewModel.downloadAllTapped()

        switch viewModel.bundlePhase {
        case .error(let message):
            #expect(message.contains("VAD"))
        default:
            Issue.record("Expected .error phase, got \(viewModel.bundlePhase)")
            return
        }

        #expect(viewModel.modelStates[.vadSilero] == .error)
        #expect(viewModel.currentModelStatusText == "Installed")
    }

    @Test
    func testRefreshSetsBundlePhaseForReadyAndMissingStates() async throws {
        let workspaceService = MockWorkspaceService()
        let mockService = MockModelInstallService()
        await mockService.setCanInstallModels(true)
        for group in ModelGroup.allCases {
            await mockService.setState(.ready, for: group)
        }

        let viewModel = SettingsViewModel(
            workspaceService: workspaceService,
            modelInstallService: mockService,
            speakerEmbeddingStore: try makeSpeakerEmbeddingStore()
        )

        await viewModel.refresh()
        #expect(viewModel.bundlePhase == .allReady)

        await mockService.setState(.missing, for: .vadSilero)
        await viewModel.refresh()
        #expect(viewModel.bundlePhase == .idle)
    }

    @Test
    func testRefreshReportsLSEENDMissingAfterLegacyThreeGroupInstall() async throws {
        let workspaceService = MockWorkspaceService()
        let mockService = MockModelInstallService()
        await mockService.setCanInstallModels(true)
        await mockService.setState(.ready, for: .asrParakeetV3)
        await mockService.setState(.ready, for: .vadSilero)
        await mockService.setState(.ready, for: .offlineDiarization)
        await mockService.setState(.missing, for: .lseendDiarization)

        let viewModel = SettingsViewModel(
            workspaceService: workspaceService,
            modelInstallService: mockService,
            speakerEmbeddingStore: try makeSpeakerEmbeddingStore()
        )

        await viewModel.refresh()

        #expect(viewModel.bundlePhase == .idle)
        #expect(viewModel.modelStates[.lseendDiarization] == .missing)
    }

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func makeSpeakerEmbeddingStore() throws -> SpeakerEmbeddingStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SpeakerProfile.self, configurations: config)
        return SpeakerEmbeddingStore(modelContainer: container)
    }
}

private actor MockModelInstallService: ModelInstallServicing {
    enum MockError: LocalizedError {
        case installFailed(ModelGroup)

        var errorDescription: String? {
            switch self {
            case .installFailed(let group):
                return "Failed to download \(group.title) models."
            }
        }
    }

    private var installable = true
    private var states: [ModelGroup: ModelGroupReadinessState] = [:]
    private var groupsInstalled: [ModelGroup] = []
    private var failGroup: ModelGroup?
    private var warmedUp = false
    private var warmUpHook: (@Sendable () async -> Void)?

    init() {
        for group in ModelGroup.allCases {
            states[group] = .missing
        }
    }

    func setCanInstallModels(_ value: Bool) {
        installable = value
    }

    func setState(_ state: ModelGroupReadinessState, for group: ModelGroup) {
        states[group] = state
    }

    func setFailureGroup(_ group: ModelGroup?) {
        failGroup = group
    }

    func setWarmUpHook(_ hook: @escaping @Sendable () async -> Void) {
        warmUpHook = hook
    }

    func installOrder() -> [ModelGroup] {
        groupsInstalled
    }

    func didWarmUp() -> Bool {
        warmedUp
    }

    func canInstallModels() async -> Bool {
        installable
    }

    func state(for group: ModelGroup) async -> ModelGroupReadinessState {
        states[group] ?? .missing
    }

    func installModelGroup(
        _ group: ModelGroup,
        progress: (@Sendable (ModelGroupReadinessState) -> Void)? = nil,
        downloadProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        groupsInstalled.append(group)
        progress?(.downloading)

        for value in [0.1, 0.6, 1.0] {
            downloadProgress?(value)
            await Task.yield()
        }

        if failGroup == group {
            progress?(.error)
            throw MockError.installFailed(group)
        }

        progress?(.ready)
        states[group] = .ready

        return URL(fileURLWithPath: "/tmp/\(group.rawValue)", isDirectory: true)
    }

    func warmUpModels(workspace: Workspace) async {
        await warmUpHook?()
        warmedUp = true
        await Task.yield()
    }
}

private actor BundlePhaseProbe {
    private var phases: [BundleInstallPhase] = []

    func record(_ phase: BundleInstallPhase) {
        if phases.last != phase {
            phases.append(phase)
        }
    }

    func snapshot() -> [BundleInstallPhase] {
        phases
    }
}
