import CryptoKit
import Foundation

enum SpliceError: Error, Equatable {
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
    /// Merges speech from both passes before taking the midpoint of each internal silent gap.
    static func cutPoints(transcript: Transcript?, retranscript: Transcript?, duration: Double) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let intervals = [transcript, retranscript].compactMap { $0 }.flatMap(\.segments)
            .compactMap { segment -> (Double, Double)? in
                let start = Double(segment.startTime), end = Double(segment.endTime)
                guard start.isFinite, end.isFinite, start <= end, end >= 0, start <= duration else { return nil }
                return (max(0, start), min(duration, end))
            }
            .sorted { $0.0 < $1.0 }
        guard let first = intervals.first else { return [] }
        var end = first.1
        var points: [Double] = []
        for interval in intervals.dropFirst() {
            if interval.0 > end {
                points.append(end + (interval.0 - end) / 2)
            }
            end = max(end, interval.1)
        }
        return points
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
        let allowed = Set(cutPoints(transcript: transcript, retranscript: retranscript, duration: duration))
        var previous = 0.0
        for cut in plan.cuts {
            guard cut.isFinite, cut > previous, cut < duration, allowed.contains(cut) else {
                throw SpliceError.invalidPlan
            }
            previous = cut
        }
    }

    /// Part ownership depends only on the start. Out-of-range starts stay at the nearest edge;
    /// a non-finite start stays in the first part. Malformed segments are never silently lost.
    static func slice(_ transcript: Transcript, cuts: [Double], originSessionID: UUID) -> [Transcript] {
        var segments = Array(repeating: [TranscriptSegment](), count: cuts.count + 1)
        for segment in transcript.segments {
            let start = Double(segment.startTime)
            let index = start.isFinite ? (cuts.firstIndex(where: { start < $0 }) ?? cuts.count) : 0
            let offset = Float(index == 0 ? 0 : cuts[index - 1])
            segments[index].append(TranscriptSegment(
                id: segment.id, speakerId: segment.speakerId, text: segment.text,
                startTime: segment.startTime - offset, endTime: segment.endTime - offset,
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
