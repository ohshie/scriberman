import Foundation

/// Speaker edits on a saved transcript. Each takes a transcript and returns the edited copy, so
/// every field an edit does not touch, such as the voiceprint space, survives it. Writing the
/// result and teaching speaker memory are the caller's.
enum TranscriptSpeakerEditing {
    private static let unnamedPrefix = "Speaker "

    /// Whether `label` is "Speaker" followed by a space and a positive integer, the form
    /// transcription gives a speaker no profile matched.
    static func isUnnamed(label: String) -> Bool {
        guard label.hasPrefix(unnamedPrefix) else { return false }
        let number = label.dropFirst(unnamedPrefix.count)
        guard let value = Int(number), value > 0 else { return false }
        return String(value) == number
    }

    /// `Speaker N` for the smallest positive N no speaker of `transcript` other than `excludedID`
    /// is labelled with.
    static func nextUnnamedLabel(in transcript: Transcript, excluding excludedID: String? = nil) -> String {
        let taken = Set(transcript.speakers.filter { $0.id != excludedID }.map(\.label))
        var number = 1
        while taken.contains(unnamedPrefix + String(number)) {
            number += 1
        }
        return unnamedPrefix + String(number)
    }

    /// Gives speaker `id` the label `label`. `nil` when the speaker is not in the transcript.
    static func rename(_ id: String, to label: String, in transcript: Transcript) -> Transcript? {
        guard let index = transcript.speakers.firstIndex(where: { $0.id == id }) else { return nil }
        var edited = transcript
        let speaker = transcript.speakers[index]
        edited.speakers[index] = TranscriptSpeaker(id: speaker.id, label: label, colorHex: speaker.colorHex)
        return edited
    }

    /// Gives every segment of speaker `id` the ID of speaker `targetID`, removes `id` from the
    /// speaker list, and appends its voiceprints to the target's. `nil` when either speaker is
    /// missing or they are the same.
    static func merge(_ id: String, into targetID: String, in transcript: Transcript) -> Transcript? {
        guard id != targetID,
              transcript.speakers.contains(where: { $0.id == id }),
              transcript.speakers.contains(where: { $0.id == targetID })
        else { return nil }
        var edited = transcript
        edited.segments = transcript.segments.map { $0.speakerId == id ? $0.withSpeakerID(targetID) : $0 }
        edited.speakers.removeAll { $0.id == id }
        if var voiceprints = edited.speakerVoiceprints, let merged = voiceprints.removeValue(forKey: id) {
            voiceprints[targetID, default: []].append(contentsOf: merged)
            edited.speakerVoiceprints = voiceprints
        }
        return edited
    }

    /// Gives speaker `id` the label `Speaker N` for the smallest N no other speaker uses. `nil` when
    /// the speaker is not in the transcript.
    static func reset(_ id: String, in transcript: Transcript) -> Transcript? {
        rename(id, to: nextUnnamedLabel(in: transcript, excluding: id), in: transcript)
    }

    /// Gives the segments `segmentIDs` the speaker `targetID`, and removes every speaker left with
    /// no segments from the speaker list. Voiceprints do not change.
    static func reassign(segmentIDs: Set<UUID>, to targetID: String, in transcript: Transcript) -> Transcript {
        var edited = transcript
        edited.segments = transcript.segments.map { segmentIDs.contains($0.id) ? $0.withSpeakerID(targetID) : $0 }
        let speaking = Set(edited.segments.map(\.speakerId))
        edited.speakers.removeAll { !speaking.contains($0.id) }
        return edited
    }

    /// Appends a speaker with a new session-local ID, the next free `Speaker N` label and no
    /// voiceprints.
    /// - Returns: the edited transcript and the new speaker's ID.
    static func addSpeaker(to transcript: Transcript) -> (transcript: Transcript, speakerID: String) {
        let taken = Set(transcript.speakers.map(\.id) + transcript.segments.map(\.speakerId))
        var id: String
        repeat {
            id = "speaker_added_" + UUID().uuidString.prefix(8).lowercased()
        } while taken.contains(id)
        var edited = transcript
        edited.speakers.append(TranscriptSpeaker(
            id: id,
            label: nextUnnamedLabel(in: transcript),
            colorHex: SpeakerPalette.colorHex(at: transcript.speakers.count)
        ))
        return (edited, id)
    }
}

private extension TranscriptSegment {
    func withSpeakerID(_ speakerID: String) -> TranscriptSegment {
        TranscriptSegment(
            id: id,
            speakerId: speakerID,
            text: text,
            startTime: startTime,
            endTime: endTime,
            audioSource: audioSource,
            isFinal: isFinal
        )
    }
}
