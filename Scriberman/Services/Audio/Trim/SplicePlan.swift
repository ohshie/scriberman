import CryptoKit
import Foundation

enum SpliceError: LocalizedError, Equatable {
    case invalidPlan
    case stalePlan
    case inactiveWorkspace
    case unfinishedRecording
    case missingMixdown
    case missingTranscript
    case missingOriginal
    case requiresTrimMigration
    case busy
    case insufficientDiskSpace
    case exportFailed

    var errorDescription: String? { SpliceCopy.errorMessage(self) }
}

struct SplicePlan: Equatable {
    struct Part: Equatable {
        var title: String
        var isDropped: Bool = false
    }

    var cuts: [Double]
    var parts: [Part]
    var transcriptFingerprint: Data

    /// Hashes the raw passes, including whether either pass is absent. Length prefixes separate
    /// the blobs even when their concatenation would be identical.
    static func fingerprint(transcriptData: Data?, retranscriptData: Data?) -> Data {
        var bytes = Data()
        for pass in [transcriptData, retranscriptData] {
            bytes.append(pass == nil ? 0 : 1)
            var size = UInt64(pass?.count ?? 0).bigEndian
            withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }
            if let pass { bytes.append(pass) }
        }
        return Data(SHA256.hash(data: bytes))
    }
}

extension SpliceService {
    /// Where a cut may go: one range per boundary between two consecutive segments of the displayed
    /// pass. A silent gap is a range; touching or overlapping segments leave the single time where
    /// the later one starts. The hidden pass is sliced at the same times.
    static func cutRanges(transcript: Transcript?, retranscript: Transcript?, duration: Double) -> [ClosedRange<Double>] {
        guard duration.isFinite, duration > 0, let displayed = retranscript ?? transcript else { return [] }
        let intervals = displayed.segments
            .compactMap { segment -> (Double, Double)? in
                let start = Double(segment.startTime), end = Double(segment.endTime)
                guard start.isFinite, end.isFinite, start <= end, end >= 0, start <= duration else { return nil }
                return (max(0, start), min(duration, end))
            }
            .sorted { $0.0 < $1.0 }
        guard let first = intervals.first else { return [] }
        var end = first.1
        var ranges: [ClosedRange<Double>] = []
        for interval in intervals.dropFirst() {
            let range = min(end, interval.0)...interval.0
            end = max(end, interval.1)
            // Segments that start together share one boundary, and nothing is cut off at either edge.
            guard interval.0 > 0, interval.0 < duration, ranges.last?.upperBound != interval.0 else { continue }
            ranges.append(range)
        }
        return ranges
    }

    /// One time per cut range: the middle of a silent gap, or the boundary itself.
    static func cutPoints(transcript: Transcript?, retranscript: Transcript?, duration: Double) -> [Double] {
        cutRanges(transcript: transcript, retranscript: retranscript, duration: duration).map {
            $0.lowerBound + ($0.upperBound - $0.lowerBound) / 2
        }
    }

    static func validate(
        plan: SplicePlan, duration: Double, transcript: Transcript?, retranscript: Transcript?,
        transcriptData: Data?, retranscriptData: Data?
    ) throws {
        guard plan.transcriptFingerprint == SplicePlan.fingerprint(
            transcriptData: transcriptData, retranscriptData: retranscriptData
        ) else { throw SpliceError.stalePlan }
        guard duration.isFinite, duration > 0, !plan.cuts.isEmpty,
              plan.parts.count == plan.cuts.count + 1,
              plan.parts.contains(where: { !$0.isDropped }) else { throw SpliceError.invalidPlan }
        let allowed = cutRanges(transcript: transcript, retranscript: retranscript, duration: duration)
        var previous = 0.0
        for cut in plan.cuts {
            guard cut.isFinite, cut > previous, cut < duration,
                  allowed.contains(where: { $0.contains(cut) }) else {
                throw SpliceError.invalidPlan
            }
            previous = cut
        }
    }

    /// Part ownership depends only on the start. Out-of-range starts stay at the nearest edge;
    /// a non-finite start stays in the first part. Malformed segments are never silently lost. A
    /// segment that runs past its part's end keeps its text and ends with the part.
    static func slice(_ transcript: Transcript, cuts: [Double], originSessionID: UUID) -> [Transcript] {
        var segments = Array(repeating: [TranscriptSegment](), count: cuts.count + 1)
        for segment in transcript.segments {
            let start = Double(segment.startTime)
            let index = start.isFinite ? (cuts.firstIndex(where: { start < $0 }) ?? cuts.count) : 0
            let offset = Float(index == 0 ? 0 : cuts[index - 1])
            var end = segment.endTime
            if index < cuts.count, start.isFinite, end.isFinite { end = min(end, Float(cuts[index])) }
            segments[index].append(TranscriptSegment(
                id: segment.id, speakerId: segment.speakerId, text: segment.text,
                startTime: segment.startTime - offset, endTime: end - offset,
                audioSource: segment.audioSource, isFinal: segment.isFinal
            ))
        }
        return segments.map { partSegments in
            var part = transcript
            let speakerIDs = Set(partSegments.map(\.speakerId))
            part.segments = partSegments
            part.fullText = Transcript.fullText(joining: partSegments)
            part.speakers = transcript.speakers.filter { speakerIDs.contains($0.id) }
            part.speakerVoiceprints = transcript.speakerVoiceprints?.filter { speakerIDs.contains($0.key) }
            part.speakerProfileIDs = transcript.speakerProfileIDs?.filter { speakerIDs.contains($0.key) }
            part.spliceOriginSessionID = transcript.spliceOriginSessionID ?? originSessionID
            return part
        }
    }
}
