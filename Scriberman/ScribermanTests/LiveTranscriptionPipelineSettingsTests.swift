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
    }

    @Test
    func settingsViewModelRoundTripAllFourKnobs() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let vm = makeViewModel(userDefaults: userDefaults)

        vm.vadThreshold = 0.92
        vm.vadMinSpeechDuration = 0.75
        vm.asrConfidenceGate = 0.40
        vm.asrAmplitudeGate = 0.05

        let vm2 = makeViewModel(userDefaults: userDefaults)

        #expect(vm2.vadThreshold == 0.92)
        #expect(vm2.vadMinSpeechDuration == 0.75)
        #expect(vm2.asrConfidenceGate == 0.40)
        #expect(vm2.asrAmplitudeGate == 0.05)
    }

    @Test
    func pipelineSettingsAssemblesAllFourKnobs() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.assembly.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let vm = makeViewModel(userDefaults: userDefaults)
        vm.vadThreshold = 0.90
        vm.vadMinSpeechDuration = 0.50
        vm.asrConfidenceGate = 0.30
        vm.asrAmplitudeGate = 0.02

        let settings = vm.pipelineSettings
        #expect(settings.vadThreshold == 0.90)
        #expect(settings.vadMinSpeechDuration == 0.50)
        #expect(settings.asrConfidenceGate == 0.30)
        #expect(settings.asrAmplitudeGate == 0.02)
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
    }

    /// Spec scenario "Stored clustering values are ignored".
    @Test
    func storedClusteringValuesAreIgnored() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.clustering.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(0.75, forKey: "speakerThreshold")
        userDefaults.set(1.2, forKey: "minSilenceGap")

        let vm = makeViewModel(userDefaults: userDefaults)
        vm.resetAllPipelineSettingsToDefaults()

        let d = LiveTranscriptionPipelineSettings.defaults
        #expect(vm.pipelineSettings.vadThreshold == d.vadThreshold)
        #expect(vm.pipelineSettings.vadMinSpeechDuration == d.vadMinSpeechDuration)
        // Left in place, unread and unwritten.
        #expect(userDefaults.double(forKey: "speakerThreshold") == 0.75)
        #expect(userDefaults.double(forKey: "minSilenceGap") == 1.2)
    }

    @Test
    func resetToDefaultsRestoresAllFourKnobs() {
        var settings = LiveTranscriptionPipelineSettings(
            vadThreshold: 0.99,
            vadMinSpeechDuration: 1.5,
            asrConfidenceGate: 0.7,
            asrAmplitudeGate: 0.05
        )
        settings.resetToDefaults()
        let d = LiveTranscriptionPipelineSettings.defaults
        #expect(settings.vadThreshold == d.vadThreshold)
        #expect(settings.vadMinSpeechDuration == d.vadMinSpeechDuration)
        #expect(settings.asrConfidenceGate == d.asrConfidenceGate)
        #expect(settings.asrAmplitudeGate == d.asrAmplitudeGate)
    }

    @Test
    func resetAllPipelineSettingsToDefaultsResetsAllFiveKnobs() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.resetAll.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let audioUD = UserDefaults(suiteName: suiteName + ".audio")!
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            audioUD.removePersistentDomain(forName: suiteName + ".audio")
        }

        let audioSettings = AppAudioSettings(userDefaults: audioUD)
        let vm = makeViewModel(userDefaults: userDefaults, appAudioSettings: audioSettings)

        vm.vadThreshold = 0.60
        vm.vadMinSpeechDuration = 1.0
        vm.asrConfidenceGate = 0.5
        vm.asrAmplitudeGate = 0.03
        audioSettings.voiceProcessingEnabled = true

        vm.resetAllPipelineSettingsToDefaults()

        let d = LiveTranscriptionPipelineSettings.defaults
        #expect(vm.vadThreshold == d.vadThreshold)
        #expect(vm.vadMinSpeechDuration == d.vadMinSpeechDuration)
        #expect(vm.asrConfidenceGate == d.asrConfidenceGate)
        #expect(vm.asrAmplitudeGate == d.asrAmplitudeGate)
        #expect(audioSettings.voiceProcessingEnabled == false)

        #expect(userDefaults.double(forKey: "vadThreshold") == d.vadThreshold)
        #expect(userDefaults.double(forKey: "vadMinSpeechDuration") == d.vadMinSpeechDuration)
        #expect(audioUD.bool(forKey: "audio.voiceProcessingEnabled") == false)
    }

    @Test
    func cleanupRulesPersistRoundTrip() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.rules.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let vm = makeViewModel(userDefaults: userDefaults)
        #expect(vm.cleanupRules.isEmpty)

        let rule = TranscriptCleanupRule(pattern: "huh", position: .end, wholeWord: true)
        vm.cleanupRules = [rule]

        let vm2 = makeViewModel(userDefaults: userDefaults)
        #expect(vm2.cleanupRules == [rule])
    }

    @Test
    func cleanupRulesCorruptDataFallsBackToEmpty() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.rulesCorrupt.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(Data("not json".utf8), forKey: "transcriptCleanupRules")

        let vm = makeViewModel(userDefaults: userDefaults)
        #expect(vm.cleanupRules.isEmpty)
    }

    @Test
    func pipelineSettingsCarriesCleanupRules() {
        let suiteName = "LiveTranscriptionPipelineSettingsTests.rulesCarry.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let vm = makeViewModel(userDefaults: userDefaults)
        let rule = TranscriptCleanupRule(pattern: "damn", position: .anywhere, wholeWord: false)
        vm.cleanupRules = [rule]

        #expect(vm.pipelineSettings.cleanupRules == [rule])
        #expect(LiveTranscriptionPipelineSettings.defaults.cleanupRules.isEmpty)
    }

    private func makeViewModel(userDefaults: UserDefaults, appAudioSettings: AppAudioSettings = AppAudioSettings()) -> SettingsViewModel {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: SpeakerProfile.self, configurations: config)
        let store = SpeakerEmbeddingStore(modelContainer: container)
        return SettingsViewModel(
            workspaceService: MockWorkspaceService(),
            modelInstallService: PipelineSettingsTestsMockModelInstallService(),
            speakerEmbeddingStore: store,
            appAudioSettings: appAudioSettings,
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
    func clearStaging() async throws {}
    func warmUpModels(workspace: Workspace) async -> [ModelGroup: String] { [:] }
}

private enum ModelInstallError: Error {
    case noWorkspace
}
