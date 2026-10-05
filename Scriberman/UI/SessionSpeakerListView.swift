import SwiftUI

/// What the session speaker list shows for a transcript, apart from the view.
enum SessionSpeakerList {
    struct Row: Identifiable, Equatable {
        let speaker: TranscriptSpeaker
        /// Whether a stored profile has the speaker's label, case-insensitively.
        let isMatched: Bool
        let audioSource: AudioSource?
        /// The sum of the speaker's segment durations, in seconds.
        let talkTime: Float

        var id: String { speaker.id }
        /// "Reset name" is offered only for a named speaker.
        var canReset: Bool { !TranscriptSpeakerEditing.isUnnamed(label: speaker.label) }
    }

    static func rows(for transcript: Transcript, profiles: [SpeakerProfileSnapshot]) -> [Row] {
        let profileNames = Set(profiles.map { $0.name.lowercased() })
        let times = talkTimes(in: transcript)
        return TranscriptGrouper.displaySpeakers(of: transcript).map { speaker in
            Row(
                speaker: speaker,
                isMatched: profileNames.contains(speaker.label.lowercased()),
                audioSource: transcript.segments.first { $0.speakerId == speaker.id }?.audioSource,
                talkTime: times[speaker.id] ?? 0
            )
        }
    }

    /// Speaker ID → the sum of `endTime - startTime` over its segments.
    static func talkTimes(in transcript: Transcript) -> [String: Float] {
        transcript.segments.reduce(into: [:]) { times, segment in
            times[segment.speakerId, default: 0] += max(segment.endTime - segment.startTime, 0)
        }
    }
}

/// Every speaker of the displayed transcript, with rename, merge and reset.
struct SessionSpeakerListView: View {
    let transcript: Transcript
    let profiles: [SpeakerProfileSnapshot]
    let onRename: (String, String) -> Void
    let onMerge: (String, String) -> Void
    let onReset: (String) -> Void

    @State private var renamingSpeakerID: String?

    var body: some View {
        let rows = SessionSpeakerList.rows(for: transcript, profiles: profiles)
        VStack(alignment: .leading, spacing: 4) {
            Text("Speakers")
                .font(.headline)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)

            ForEach(rows) { row in
                speakerRow(row, others: rows.filter { $0.id != row.id })
                    .zIndex(renamingSpeakerID == row.id ? 1 : 0)
            }
        }
        .padding(12)
        .frame(width: 400, alignment: .leading)
    }

    private func speakerRow(_ row: SessionSpeakerList.Row, others: [SessionSpeakerList.Row]) -> some View {
        let color = Color(hex: row.speaker.colorHex) ?? .accentColor
        return HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            if renamingSpeakerID == row.id {
                SpeakerNameField(
                    name: row.speaker.label,
                    profiles: profiles,
                    onCommit: { name in
                        onRename(row.id, name)
                        renamingSpeakerID = nil
                    },
                    onCancel: {
                        if renamingSpeakerID == row.id {
                            renamingSpeakerID = nil
                        }
                    }
                )
            } else {
                Text(row.speaker.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            if row.isMatched {
                Image(systemName: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(color)
                    .accessibilityLabel("Matched to a profile")
            }

            Spacer(minLength: 8)

            if let audioSource = row.audioSource {
                Image(systemName: audioSource == .app ? "speaker.wave.2.fill" : "mic.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(TimeFormatter.format(seconds: row.talkTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 2) {
                Button {
                    renamingSpeakerID = row.id
                } label: {
                    Image(systemName: "pencil")
                }
                .help("Rename speaker")
                .accessibilityLabel("Rename speaker")

                Menu {
                    Section("merge into") {
                        ForEach(others) { other in
                            Button {
                                onMerge(row.id, other.id)
                            } label: {
                                Label {
                                    Text(other.speaker.label)
                                } icon: {
                                    Image(nsImage: SpeakerDotImage.make(hex: other.speaker.colorHex))
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.triangle.merge")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(others.isEmpty)
                .help("Merge speaker")
                .accessibilityLabel("Merge speaker")

                Button {
                    onReset(row.id)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .disabled(!row.canReset)
                .help("Reset name")
                .accessibilityLabel("Reset name")
            }
            .buttonStyle(.borderless)
            .padding(.leading, 6)
        }
        .padding(8)
    }
}
