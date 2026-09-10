import SwiftData
import SwiftUI

struct ActiveRecordingDetailView: View {
    let session: RecordingSession
    let viewModel: NewSessionViewModel
    let modelContext: ModelContext

    @FocusState private var titleFocused: Bool
    @State private var isTitleHovering = false
    /// Whether the pointer is inside the live transcript, which suspends the scroll to the newest
    /// segment.
    @State private var isPointerOverSegments = false

    init(session: RecordingSession, viewModel: NewSessionViewModel, modelContext: ModelContext) {
        self.session = session
        self.viewModel = viewModel
        self.modelContext = modelContext
    }

    /// Marks the end of the content, so following the transcript scrolls to the foot of the view —
    /// which is where the Stop button is.
    private static let bottomAnchor = "recording-view-bottom"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Title", text: editingTitle)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit {
                        titleFocused = false
                    }
                    .editableTitleHover(isHovering: $isTitleHovering)

                FlowingWaveView(
                    level: viewModel.micAudioLevel,
                    appLevel: viewModel.appAudioLevel,
                    showAppWave: viewModel.recordAppAudio,
                    isRecording: true
                )
                    .frame(height: 110)

                Text(durationText(currentDuration))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)

                if !viewModel.liveSegments.isEmpty {
                    // In the flow, not in a scroll view of their own. Two scrolling regions in one
                    // window means the wrong one moves under the pointer half the time; and a
                    // transcript penned into 120 points while the window has room is the smaller
                    // half of the problem. Arriving segments push the controls below them down.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.liveSegments, id: \.id) { segment in
                            liveSegmentRow(for: segment)
                                .id(segment.id)
                        }
                    }
                }

                HStack {
                    Spacer()
                    HeroCircleButton(
                        innerShape: .roundedSquare,
                        tint: .red,
                        caption: "Stop"
                    ) {
                        Task {
                            _ = await viewModel.stopRecording(context: modelContext)
                        }
                    }
                    Spacer()
                }

                LazyVGrid(columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading)
                ], alignment: .leading, spacing: 16) {
                    MetadataCell(
                        title: "Microphone",
                        value: viewModel.selectedDevice?.name ?? "Default",
                        systemImage: "mic.fill"
                    )

                    MetadataCell(
                        title: "Application",
                        value: viewModel.selectedApp?.name ?? "Off",
                        systemImage: "app.fill"
                    )
                }

                Color.clear
                    .frame(height: 1)
                    .id(Self.bottomAnchor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if titleFocused {
                titleFocused = false
            }
        }
        // Following the transcript means scrolling to the foot of the view, so the newest text and
        // the Stop button stay together. Suspended while the pointer is in the window: SwiftUI
        // cannot report a selection, and a pointer in here is someone reading or selecting.
        .onHover { hovering in
            isPointerOverSegments = hovering
        }
        .onChange(of: viewModel.liveSegments.count) {
            guard !isPointerOverSegments else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        }
    }

    private var currentDuration: TimeInterval {
        if case let .recording(duration, _) = viewModel.state {
            return duration
        }

        return session.duration
    }

    /// A live segment, drawn in the same card as a finished one.
    ///
    /// No speaker: diarization runs after the recording, so the source the audio came from occupies
    /// the position a speaker will later hold. Showing an empty speaker, or inventing "Speaker 1",
    /// would state something the app does not yet know.
    @ViewBuilder
    private func liveSegmentRow(for segment: TranscriptSegment) -> some View {
        TranscriptRowView(
            timeText: TimeFormatter.displayFormat(seconds: segment.startTime),
            copyText: segment.text
        ) {
            Text(segment.audioSource == .mic ? "Mic" : "App")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Capsule().stroke(.secondary.opacity(0.3)))
        } content: {
            Text(segment.text)
                .font(.body)
                // Text on screen that cannot be copied until the recording ends is a worse
                // restriction than text that could not be seen at all.
                .textSelection(.enabled)
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var editingTitle: Binding<String> {
        Binding(
            get: { session.title },
            set: { newValue in
                session.title = newValue
                try? modelContext.save()
            }
        )
    }
}
