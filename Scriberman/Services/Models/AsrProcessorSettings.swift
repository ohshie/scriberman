import CoreML
import Foundation
import Observation

/// Where the Parakeet encoder runs. The preprocessor, decoder and joint keep
/// FluidAudio's own placement whichever is chosen.
enum AsrProcessor: String, CaseIterable, Sendable {
    case gpu
    case neuralEngine

    static let defaultsKey = "asrProcessor"

    var encoderComputeUnits: MLComputeUnits {
        switch self {
        case .gpu: return .cpuAndGPU
        case .neuralEngine: return .cpuAndNeuralEngine
        }
    }

    /// The stored choice, read where models load (off the main actor).
    /// Absent or unknown values mean the GPU, the placement before this setting existed.
    static func current(defaults: UserDefaults = .standard) -> AsrProcessor {
        defaults.string(forKey: defaultsKey).flatMap(AsrProcessor.init(rawValue:)) ?? .gpu
    }
}

@Observable
@MainActor
final class AsrProcessorSettings {
    private let defaults: UserDefaults

    private(set) var processor: AsrProcessor

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.processor = AsrProcessor.current(defaults: defaults)
    }

    func setProcessor(_ newProcessor: AsrProcessor) {
        processor = newProcessor
        defaults.set(newProcessor.rawValue, forKey: AsrProcessor.defaultsKey)
    }
}
