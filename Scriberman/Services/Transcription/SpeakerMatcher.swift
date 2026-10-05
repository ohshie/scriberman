import FluidAudio
import Foundation
import OSLog

/// Cross-session speaker matching. Live and offline transcription apply the same rule: a profile
/// matches when its cosine distance to the voiceprint is at most `threshold` and at least `margin`
/// smaller than the distance to the second-closest profile. Profiles from another voiceprint
/// space are never compared.
struct SpeakerMatcher {
    static let defaultThreshold: Float = 0.40
    static let defaultMargin: Float = 0.10

    /// The closest candidates for one voiceprint, for calibration logs.
    struct Candidate: Equatable {
        let profileID: UUID
        let distance: Float
    }

    let threshold: Float
    let margin: Float
    private let log: @Sendable (String) -> Void

    init(
        threshold: Float = SpeakerMatcher.defaultThreshold,
        margin: Float = SpeakerMatcher.defaultMargin,
        log: @escaping @Sendable (String) -> Void = SpeakerMatcher.defaultLog
    ) {
        self.threshold = threshold
        self.margin = margin
        self.log = log
    }

    private static let logger = Logger(subsystem: "Scriberman", category: "SpeakerMatcher")

    /// `.notice`, not `.info`: info lines are not kept on disk, and these are read back after a
    /// session to calibrate the threshold and margin.
    @Sendable
    static func defaultLog(_ line: String) {
        logger.notice("\(line, privacy: .public)")
    }

    func findBestMatch(for embedding: [Float], in profiles: [SpeakerProfile]) -> SpeakerProfile? {
        let snapshots = profiles.map(SpeakerProfileSnapshot.init(profile:))
        guard let match = findBestMatch(for: embedding, in: snapshots) else { return nil }
        return profiles.first { $0.id == match.id }
    }

    func findBestMatch(for embedding: [Float], in profiles: [SpeakerProfileSnapshot]) -> SpeakerProfileSnapshot? {
        let ranked = rank(embedding, among: profiles)
        let match = qualifyingMatch(in: ranked)
        logDecision(query: "single", ranked: ranked, match: match)
        return match
    }

    /// Matches the voiceprints of one audio source, giving each profile to at most one of them.
    ///
    /// Repeatedly fixes the closest query-profile pair that satisfies the rule, removes both, and
    /// re-evaluates the remaining queries against the remaining profiles, so a query whose best
    /// profile was taken can still match its runner-up under the same threshold and margin.
    /// - Parameter queries: speaker label and voiceprint, in a stable order (used for ties).
    /// - Returns: label → matched profile, for matched labels only.
    func assign(
        _ queries: [(label: String, embedding: [Float])],
        to profiles: [SpeakerProfileSnapshot]
    ) -> [String: SpeakerProfileSnapshot] {
        var remainingProfiles = profiles
        var remainingQueries = queries.filter { !$0.embedding.isEmpty }
        var result: [String: SpeakerProfileSnapshot] = [:]

        while true {
            var best: (queryIndex: Int, profile: SpeakerProfileSnapshot, distance: Float)?
            for (index, query) in remainingQueries.enumerated() {
                let ranked = rank(query.embedding, among: remainingProfiles)
                guard let match = qualifyingMatch(in: ranked), let distance = ranked.first?.distance else { continue }
                if best == nil || distance < best!.distance {
                    best = (index, match, distance)
                }
            }
            guard let best else { break }
            result[remainingQueries[best.queryIndex].label] = best.profile
            remainingQueries.remove(at: best.queryIndex)
            remainingProfiles.removeAll { $0.id == best.profile.id }
        }

        for query in queries where !query.embedding.isEmpty {
            logDecision(query: query.label, ranked: rank(query.embedding, among: profiles), match: result[query.label])
        }
        return result
    }

    // MARK: - Private

    private func rank(
        _ embedding: [Float],
        among profiles: [SpeakerProfileSnapshot]
    ) -> [(profile: SpeakerProfileSnapshot, distance: Float)] {
        guard !embedding.isEmpty else { return [] }
        return profiles
            .filter {
                $0.voiceprintSpace == VoiceprintSpace.current
                    && !$0.embedding.isEmpty
                    && $0.embedding.count == embedding.count
            }
            .map { ($0, SpeakerUtilities.cosineDistance(embedding, $0.embedding)) }
            .sorted { $0.distance < $1.distance }
    }

    /// The closest profile when it is within `threshold` and at least `margin` ahead of the
    /// runner-up. An exact tie has zero margin and never matches.
    private func qualifyingMatch(
        in ranked: [(profile: SpeakerProfileSnapshot, distance: Float)]
    ) -> SpeakerProfileSnapshot? {
        guard let first = ranked.first, first.distance <= threshold else { return nil }
        if ranked.count > 1, ranked[1].distance - first.distance < margin {
            return nil
        }
        return first.profile
    }

    private func logDecision(
        query: String,
        ranked: [(profile: SpeakerProfileSnapshot, distance: Float)],
        match: SpeakerProfileSnapshot?
    ) {
        let candidates = ranked.prefix(2)
            .map { "\($0.profile.id.uuidString)=\(String(format: "%.3f", $0.distance))" }
            .joined(separator: " ")
        let outcome = match.map { "matched \($0.id.uuidString)" } ?? "unmatched"
        log("speaker match [\(query)] \(outcome); top: \(candidates.isEmpty ? "none" : candidates)")
    }
}
