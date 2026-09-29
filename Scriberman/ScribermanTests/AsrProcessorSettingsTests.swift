import CoreML
import Foundation
import Testing
@testable import Scriberman

@MainActor
struct AsrProcessorSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "AsrProcessorSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test
    func absentValueIsGPU() {
        let defaults = makeDefaults()
        #expect(AsrProcessorSettings(defaults: defaults).processor == .gpu)
        #expect(AsrProcessor.current(defaults: defaults) == .gpu)
    }

    @Test
    func selectionPersistsAndTheLoadReaderSeesIt() {
        let defaults = makeDefaults()
        AsrProcessorSettings(defaults: defaults).setProcessor(.neuralEngine)
        #expect(AsrProcessorSettings(defaults: defaults).processor == .neuralEngine)
        #expect(AsrProcessor.current(defaults: defaults) == .neuralEngine)
    }

    @Test
    func unknownStoredValueIsGPU() {
        let defaults = makeDefaults()
        defaults.set("cpuOnly", forKey: AsrProcessor.defaultsKey)
        #expect(AsrProcessor.current(defaults: defaults) == .gpu)
    }

    @Test
    func processorsMapToEncoderComputeUnits() {
        #expect(AsrProcessor.gpu.encoderComputeUnits == .cpuAndGPU)
        #expect(AsrProcessor.neuralEngine.encoderComputeUnits == .cpuAndNeuralEngine)
    }
}
