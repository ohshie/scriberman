import Foundation
import SwiftData
import Testing
@testable import Scriberman

@MainActor
@Suite
struct LiveTranscriptionPipelineSettingsTests {
    @Test
    func defaultsMatchSpec() {
        let d = LiveTranscriptionPipelineSettings.defaults
        #expect(d.vadThreshold == 0.85)
        #expect(d.vadMinSpeechDuration == 0.30)
        #expect(d.asrConfidenceGate == 0.0)
        #expect(d.asrAmplitudeGate == 0.0)
        #expect(d.speakerSimilarityThreshold == 0.65)
        #expect(d.minSilenceGap == 0.50)
    }

    @Test
    func settingsViewModelRoundTripAllSixKnobs() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let vm = makeViewModel(userDefaults: userDefaults)

        vm.vadThreshold = 0.92
        vm.vadMinSpeechDuration = 0.75
        vm.asrConfidenceGate = 0.40
        vm.asrAmplitudeGate = 0.05
        vm.speakerThreshold = 0.80
        vm.minSilenceGap = 1.2

        let vm2 = makeViewModel(userDefaults: userDefaults)

        #expect(vm2.vadThreshold == 0.92)
        #expect(vm2.vadMinSpeechDuration == 0.75)
        #expect(vm2.asrConfidenceGate == 0.40)
        #expect(vm2.asrAmplitudeGate == 0.05)
        #expect(vm2.speakerThreshold == 0.80)
        #expect(vm2.minSilenceGap == 1.2)
    }

    @Test
    func pipelineSettingsAssemblesAllSixKnobs() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.assembly.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let vm = makeViewModel(userDefaults: userDefaults)
        vm.vadThreshold = 0.90
        vm.vadMinSpeechDuration = 0.50
        vm.asrConfidenceGate = 0.30
        vm.asrAmplitudeGate = 0.02
        vm.speakerThreshold = 0.75
        vm.minSilenceGap = 0.80

        let settings = vm.pipelineSettings
        #expect(settings.vadThreshold == 0.90)
        #expect(settings.vadMinSpeechDuration == 0.50)
        #expect(settings.asrConfidenceGate == 0.30)
        #expect(settings.asrAmplitudeGate == 0.02)
        #expect(settings.speakerSimilarityThreshold == 0.75)
        #expect(settings.minSilenceGap == 0.80)
    }

    @Test
    func freshInstallUsesDefaults() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.fresh.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let vm = makeViewModel(userDefaults: userDefaults)

        let d = LiveTranscriptionPipelineSettings.defaults
        #expect(vm.vadThreshold == d.vadThreshold)
        #expect(vm.vadMinSpeechDuration == d.vadMinSpeechDuration)
        #expect(vm.asrConfidenceGate == d.asrConfidenceGate)
        #expect(vm.asrAmplitudeGate == d.asrAmplitudeGate)
        #expect(vm.speakerThreshold == d.speakerSimilarityThreshold)
        #expect(vm.minSilenceGap == d.minSilenceGap)
    }

    private func makeViewModel(userDefaults: UserDefaults) -> SettingsViewModel {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: SpeakerProfile.self, configurations: config)
        let store = SpeakerEmbeddingStore(modelContainer: container)
        return SettingsViewModel(
            workspaceService: MockWorkspaceService(),
            modelInstallService: PipelineSettingsTestsMockModelInstallService(),
            speakerEmbeddingStore: store,
            userDefaults: userDefaults
        )
    }
}

private actor PipelineSettingsTestsMockModelInstallService: ModelInstallServicing {
    func canInstallModels() async -> Bool { false }
    func state(for group: ModelGroup) async -> ModelGroupReadinessState { .missing }
    func installModelGroup(
        _ group: ModelGroup,
        progress: (@Sendable (ModelGroupReadinessState) -> Void)?,
        downloadProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        throw ModelInstallError.noWorkspace
    }
    func warmUpModels(workspace: Workspace) async {}
}

private enum ModelInstallError: Error {
    case noWorkspace
}
