import CoreAudio
import CoreML
import FluidAudio
import Foundation
import OSLog
import Observation

enum DictationState: Equatable {
    case idle
    case listening
    case prewarming
}

@Observable
@MainActor
final class DictationService {
    private let logger = Logger(subsystem: "Scriberman", category: "DictationService")

    private(set) var state: DictationState = .idle

    // nonisolated(unsafe): written once during prewarm (on main actor), then read by the processing
    // Task which only runs after prewarm completes and never concurrently with another write.
    @ObservationIgnored nonisolated(unsafe) private var asrManager: AsrManager?
    @ObservationIgnored private let modelPathResolver = ModelPathResolver()

    @ObservationIgnored private let textInjector = TextInjector()
    @ObservationIgnored private var captureSession: DictationCaptureSession?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private let recordingService: any RecordingServiceProtocol

    init(recordingService: any RecordingServiceProtocol) {
        self.recordingService = recordingService
    }

    // MARK: - Pre-warm

    func prewarm(workspace: Workspace) async {
        guard asrManager == nil else { return }
        state = .prewarming

        do {
            let asrDir = try modelPathResolver.modelDirectory(for: .asrParakeetV3, in: workspace)
            let asr = AsrManager(config: ASRConfig())
            let asrModels = try await AsrModels.load(from: asrDir, encoderComputeUnits: .cpuAndGPU)
            try await asr.loadModels(asrModels)
            asrManager = asr

            logger.info("DictationService pre-warm complete")
        } catch {
            logger.warning("DictationService pre-warm failed (non-fatal): \(error.localizedDescription)")
            asrManager = nil
        }
        state = .idle
    }

    // MARK: - Lifecycle

    func start(deviceID: AudioDeviceID?) async {
        guard state == .idle else { return }
        guard await !recordingService.isRecording() else {
            logger.info("Dictation blocked: recording is active")
            return
        }

        let session = DictationCaptureSession()
        captureSession = session
        do {
            let stream = try await session.start(deviceID: deviceID)
            state = .listening
            startProcessing(stream: stream)
        } catch {
            logger.error("Failed to start dictation capture: \(error.localizedDescription)")
            captureSession = nil
        }
    }

    func stop() async {
        await captureSession?.stop()
        captureSession = nil
        await processingTask?.value
        processingTask = nil
        state = .idle
    }

    // MARK: - Processing

    private func startProcessing(stream: AsyncStream<[Float]>) {
        let asr = asrManager
        let injector = textInjector
        let logger = logger

        processingTask = Task { [weak self] in
            var allSamples: [Float] = []

            for await samples in stream {
                guard !Task.isCancelled else { break }
                allSamples.append(contentsOf: samples)
            }

            if !allSamples.isEmpty, !Task.isCancelled {
                logger.info("Dictation transcribing full buffer with \(allSamples.count) samples")
                if let text = await Self.transcribe(allSamples, using: asr, logger: logger) {
                    Self.logTranscript(text)
                    injector.inject(text)
                } else {
                    logger.info("Dictation transcription produced no text")
                }
            }
        }
    }

    private static func transcribe(
        _ samples: [Float],
        using asr: AsrManager?,
        logger: Logger
    ) async -> String? {
        guard let asr, !samples.isEmpty else { return nil }
        do {
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            logger.error("ASR error: \(error.localizedDescription)")
            return nil
        }
    }

    private static func logTranscript(_ text: String) {
        print("Dictation transcript: \(text)")
    }
}
