import SwiftData
import SwiftUI

struct ActiveRecordingDetailView: View {
    let session: RecordingSession
    let viewModel: NewSessionViewModel
    let modelContext: ModelContext
    /// Called when a title edit fails to save; the session keeps its previous title.
    let onTitleNotSaved: () -> Void

    @FocusState private var titleFocused: Bool
    @State private var isTitleHovering = false
    /// Whether the pointer is inside the live transcript, which suspends the scroll to the newest
    /// segment.
    @State private var isPointerOverSegments = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: RecordingSession,
        viewModel: NewSessionViewModel,
        modelContext: ModelContext,
        onTitleNotSaved: @escaping () -> Void
    ) {
        self.session = session
        self.viewModel = viewModel
        self.modelContext = modelContext
        self.onTitleNotSaved = onTitleNotSaved
    }

    /// Marks the end of the content, so following the transcript scrolls to the foot of the view.
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

                Text(TimeFormatter.displayFormat(seconds: Float(currentDuration)))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)

                if !viewModel.liveSegments.isEmpty {
                    // In the flow, not in a scroll view of their own. Two scrolling regions in one
                    // window means the wrong one moves under the pointer half the time; and a
                    // transcript penned into 120 points while the window has room is the smaller
                    // half of the problem. Arriving segments push the source cards below them down.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.liveSegments, id: \.id) { segment in
                            liveSegmentRow(for: segment)
                                .id(segment.id)
                        }
                    }
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
        // Following the transcript means scrolling to the foot of the view. Suspended while the
        // pointer is in the scroll view: SwiftUI cannot report a selection, and a pointer in here is
        // someone reading or selecting.
        .onHover { hovering in
            isPointerOverSegments = hovering
        }
        .onChange(of: viewModel.liveSegments.count) {
            guard !isPointerOverSegments else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        // Outside the scrolling content, so Stop stays in the window however long the transcript
        // grows, including while following is suspended. A plain inset: a safe-area bar extends the
        // scroll edge effect under Stop, and that area lit up under the pointer.
        .safeAreaInset(edge: .bottom) {
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
            .padding(.vertical, 16)
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
        .contextMenu {
            Button("Copy") {
                copyToPasteboard(segment.text)
            }
        }
    }

    private var editingTitle: Binding<String> {
        Binding(
            get: { session.title },
            set: { newValue in
                let result = TranscriptDetailViewModel.saveTitle(newValue, of: session, context: modelContext)
                if case .saveFailed = result {
                    onTitleNotSaved()
                }
            }
        )
    }
}
