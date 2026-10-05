import CoreML
import FluidAudio
import Foundation

/// Speaker voiceprints in the current voiceprint space (wespeaker_v2), computed over each
/// speaker's single-speaker speech.
///
/// Speech where another speaker is also active is excluded, and runs shorter than
/// `minimumRunSeconds` are ignored. The audio is cut into 10 s windows, the embedding model's input
/// length; each window yields one embedding per speaker with speech in it, weighted by that speech's
/// duration. A speaker's voiceprint is the L2-normalised weighted mean, and only speakers with at
/// least `minimumSpeechSeconds` of qualifying speech get one.
struct SpeakerVoiceprintExtractor {
    /// One stretch of one speaker's activity, in seconds from the start of the samples.
    struct SpeakerRange: Equatable {
        let speaker: String
        let start: Double
        let end: Double
    }

    struct Voiceprint: Equatable {
        let embedding: [Float]
        let speechSeconds: Double
    }

    /// Embeds one window (at most 10 s of 16 kHz samples) under each mask, returning one
    /// embedding per mask. An all-zero embedding means the model produced none.
    typealias Embed = (_ window: ArraySlice<Float>, _ masks: [[Float]]) throws -> [[Float]]

    static let sampleRate = 16_000
    static let windowSeconds = 10.0
    static let minimumRunSeconds = 1.0
    static let minimumSpeechSeconds = 3.0

    /// Mask length the embedding model expects for one 10 s window.
    let maskFrameCount: Int
    let embed: Embed

    init(maskFrameCount: Int, embed: @escaping Embed) {
        self.maskFrameCount = maskFrameCount
        self.embed = embed
    }

    /// Wraps FluidAudio's wespeaker model. The mask length comes from the segmentation model's
    /// output shape, as `DiarizerManager.extractSpeakerEmbedding` derives it.
    init(models: DiarizerModels) throws {
        guard
            let shape = models.segmentationModel.modelDescription
                .outputDescriptionsByName["segments"]?.multiArrayConstraint?.shape,
            shape.count >= 2
        else {
            throw SpeakerVoiceprintExtractorError.unknownMaskFrameCount
        }
        let extractor = EmbeddingExtractor(embeddingModel: models.embeddingModel)
        self.init(maskFrameCount: shape[1].intValue) { window, masks in
            try extractor.getEmbeddings(audio: window, masks: masks)
        }
    }

    func voiceprints(
        samples: [Float],
        ranges: [SpeakerRange],
        minimumSpeechSeconds: Double = SpeakerVoiceprintExtractor.minimumSpeechSeconds
    ) throws -> [String: Voiceprint] {
        let runs = Self.exclusiveRuns(ranges)
        guard !samples.isEmpty, !runs.isEmpty else { return [:] }

        let windowSamples = Int(Self.windowSeconds) * Self.sampleRate
        var sums: [String: [Float]] = [:]
        var weights: [String: Double] = [:]

        var windowStart = 0
        while windowStart < samples.count {
            let windowEnd = min(windowStart + windowSamples, samples.count)
            let startSeconds = Double(windowStart) / Double(Self.sampleRate)
            let endSeconds = Double(windowEnd) / Double(Self.sampleRate)

            var speakers: [String] = []
            var masks: [[Float]] = []
            var speech: [Double] = []
            for speaker in runs.keys.sorted() {
                let (mask, seconds) = mask(for: runs[speaker] ?? [], windowStart: startSeconds, windowEnd: endSeconds)
                guard seconds > 0 else { continue }
                speakers.append(speaker)
                masks.append(mask)
                speech.append(seconds)
            }

            if !masks.isEmpty {
                let embeddings = try embed(samples[windowStart..<windowEnd], masks)
                for (index, speaker) in speakers.enumerated() where index < embeddings.count {
                    let embedding = embeddings[index]
                    guard !embedding.isEmpty,
                          embedding.contains(where: { $0 != 0 }),
                          embedding.allSatisfy(\.isFinite)
                    else { continue }
                    let weight = speech[index]
                    let scaled = embedding.map { $0 * Float(weight) }
                    if let sum = sums[speaker], sum.count == scaled.count {
                        sums[speaker] = zip(sum, scaled).map(+)
                    } else {
                        sums[speaker] = scaled
                    }
                    weights[speaker, default: 0] += weight
                }
            }
            windowStart = windowEnd
        }

        var result: [String: Voiceprint] = [:]
        for (speaker, sum) in sums {
            let weight = weights[speaker] ?? 0
            guard weight >= minimumSpeechSeconds else { continue }
            let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > 0 else { continue }
            result[speaker] = Voiceprint(embedding: sum.map { $0 / norm }, speechSeconds: weight)
        }
        return result
    }

    /// Each speaker's runs with every other speaker's activity removed, merged, and with runs
    /// shorter than `minimumRunSeconds` dropped.
    static func exclusiveRuns(_ ranges: [SpeakerRange]) -> [String: [ClosedRange<Double>]] {
        let bySpeaker = Dictionary(grouping: ranges.filter { $0.end > $0.start }, by: \.speaker)
            .mapValues { merged($0.map { $0.start...$0.end }) }

        var result: [String: [ClosedRange<Double>]] = [:]
        for (speaker, own) in bySpeaker {
            let others = merged(bySpeaker.filter { $0.key != speaker }.values.flatMap { $0 })
            let exclusive = subtract(others, from: own).filter { $0.upperBound - $0.lowerBound >= minimumRunSeconds }
            if !exclusive.isEmpty {
                result[speaker] = exclusive
            }
        }
        return result
    }

    // MARK: - Private

    /// The window's mask for `runs` (1 where the frame's centre lies in a run) and the seconds of
    /// those runs inside the window.
    private func mask(
        for runs: [ClosedRange<Double>],
        windowStart: Double,
        windowEnd: Double
    ) -> (mask: [Float], seconds: Double) {
        var seconds = 0.0
        for run in runs {
            seconds += max(0, min(run.upperBound, windowEnd) - max(run.lowerBound, windowStart))
        }
        guard seconds > 0 else { return ([], 0) }

        let frameSeconds = Self.windowSeconds / Double(maskFrameCount)
        var mask = Array(repeating: Float(0), count: maskFrameCount)
        for frame in 0..<maskFrameCount {
            let centre = windowStart + (Double(frame) + 0.5) * frameSeconds
            guard centre < windowEnd else { break }
            if runs.contains(where: { $0.contains(centre) }) {
                mask[frame] = 1
            }
        }
        return (mask, seconds)
    }

    private static func merged(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// `ranges` minus `removed`; both sorted and merged.
    private static func subtract(_ removed: [ClosedRange<Double>], from ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        for range in ranges {
            var pieces = [range]
            for cut in removed where cut.upperBound > range.lowerBound && cut.lowerBound < range.upperBound {
                pieces = pieces.flatMap { piece -> [ClosedRange<Double>] in
                    guard cut.upperBound > piece.lowerBound, cut.lowerBound < piece.upperBound else { return [piece] }
                    var kept: [ClosedRange<Double>] = []
                    if cut.lowerBound > piece.lowerBound { kept.append(piece.lowerBound...cut.lowerBound) }
                    if cut.upperBound < piece.upperBound { kept.append(cut.upperBound...piece.upperBound) }
                    return kept
                }
            }
            result.append(contentsOf: pieces)
        }
        return result
    }
}

enum SpeakerVoiceprintExtractorError: Error {
    case unknownMaskFrameCount
}
