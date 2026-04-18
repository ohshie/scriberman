import SwiftData
import SwiftUI

struct ActiveRecordingDetailView: View {
    let session: RecordingSession
    let viewModel: NewSessionViewModel
    let modelContext: ModelContext

    @FocusState private var titleFocused: Bool

    init(session: RecordingSession, viewModel: NewSessionViewModel, modelContext: ModelContext) {
        self.session = session
        self.viewModel = viewModel
        self.modelContext = modelContext
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TextField("Title", text: editingTitle)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .focused($titleFocused)
                    .onSubmit {
                        titleFocused = false
                    }

                FlowingWaveView(level: currentLevel, showAppWave: viewModel.recordAppAudio, isRecording: true)
                    .frame(height: 110)

                Text(durationText(currentDuration))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)

                if !viewModel.liveSegments.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(viewModel.liveSegments, id: \.id) { segment in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(segment.audioSource == .mic ? "Mic" : "App")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Capsule().stroke(.secondary.opacity(0.3)))

                                        Text(segment.text)
                                            .font(.callout)
                                            .foregroundStyle(segment.isFinal ? .primary : .secondary)
                                    }
                                    .id(segment.id)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(height: 120)
                        .onChange(of: viewModel.liveSegments.count) {
                            if let last = viewModel.liveSegments.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        Task {
                            _ = await viewModel.stopRecording(context: modelContext)
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
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
    }

    private var currentLevel: Float {
        if case let .recording(_, level) = viewModel.state {
            return level
        }

        return 0
    }

    private var currentDuration: TimeInterval {
        if case let .recording(duration, _) = viewModel.state {
            return duration
        }

        return session.duration
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
