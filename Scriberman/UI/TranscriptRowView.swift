import AppKit
import SwiftUI

/// The card a passage of transcript is drawn in, wherever it appears.
///
/// Two views draw transcript: the study view, from a finished transcript, and the recording view,
/// from segments arriving live. They were written a long way apart and looked it — the same words in
/// two visual languages, depending on whether the recording had stopped.
///
/// What they share is the card, not the behaviour. Seeking, renaming a speaker and search
/// highlighting all belong to a finished transcript; a recording in progress has none of them. So
/// this owns the appearance and takes what each caller has: an identity — a speaker, or the source a
/// live segment came from — an optional time, and the text.
struct TranscriptRowView<Identity: View, Content: View>: View {
    /// What names this passage: a speaker in a finished transcript, a source while recording.
    let identity: Identity
    /// When the passage starts, or `nil` while recording, where nothing can be seeked to yet.
    var timeText: String?
    /// Drawn at the trailing edge when the identity does not already say where the audio came from.
    var audioSource: AudioSource?
    /// The text the copy control puts on the pasteboard — the words alone, without the speaker or
    /// the time, which is what someone quoting a transcript would otherwise have to delete.
    let copyText: String
    /// The block being played, which the finished transcript lifts.
    var isActive: Bool = false
    var activeColor: Color = .accentColor
    let content: Content

    @State private var isHovering = false

    init(
        timeText: String? = nil,
        audioSource: AudioSource? = nil,
        copyText: String,
        isActive: Bool = false,
        activeColor: Color = .accentColor,
        @ViewBuilder identity: () -> Identity,
        @ViewBuilder content: () -> Content
    ) {
        self.timeText = timeText
        self.audioSource = audioSource
        self.copyText = copyText
        self.isActive = isActive
        self.activeColor = activeColor
        self.identity = identity()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                identity

                if let timeText {
                    Text(timeText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Only under the pointer: a list of passages with a button on every one of them
                // reads as a toolbar rather than as a transcript.
                if isHovering {
                    Button {
                        copy()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    .accessibilityLabel("Copy")
                    .transition(.opacity)
                }

                if let audioSource {
                    Image(systemName: audioSource == .app ? "speaker.wave.2.fill" : "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isActive ? activeColor.opacity(0.4) : .clear, lineWidth: 1.5)
        }
        .scaleEffect(isActive ? 1.01 : 1)
        .shadow(color: isActive ? Color("ActiveBlockShadow") : .clear, radius: 6, x: 0, y: 3)
        .animation(.easeOut(duration: 0.15), value: isActive)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copyText, forType: .string)
    }
}
