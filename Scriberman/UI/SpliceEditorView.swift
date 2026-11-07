import AppKit
import SwiftUI

struct SpliceEditorView: View {
    let editor: SpliceEditorViewModel
    let player: AudioPlayerViewModel
    let transcript: Transcript?
    let audioURL: URL
    let onCancel: () -> Void
    let onApply: () -> Void
    @State private var peaks: [Float] = []
    @State private var hoveredMarker: UUID?
    @State private var draggedMarker: UUID?
    @State private var draggedStart = 0.0
    @State private var dragOffTimeline = false

    var body: some View {
        VStack(spacing: 10) {
            controls
            timeline
            bands
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).stroke(.primary.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.1), radius: 14, y: 5)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .disabled(editor.isApplying)
        .task(id: audioURL) {
            do { peaks = try await AudioSampleReader().peaks(from: audioURL) }
            catch { peaks = [] }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if player.isPlaying { player.pause() } else { player.play() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Text("\(time(player.currentTime)) / \(time(editor.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: editor.undo) { Image(systemName: "arrow.uturn.backward") }
                .help("Undo")
                .accessibilityLabel("Undo")
                .disabled(!editor.canUndo)
            Divider().frame(height: 18)
            Button(action: onCancel) { Image(systemName: "xmark") }
                .help("Close without splicing")
                .accessibilityLabel("Cancel")
            Button(action: onApply) {
                HStack(spacing: 6) {
                    if editor.isApplying { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark") }
                    Text(editor.keptCount, format: .number)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .help(SpliceCopy.apply(editor.keptCount))
            .accessibilityLabel(SpliceCopy.apply(editor.keptCount))
            .disabled(!editor.canApply)
        }
        .buttonStyle(.borderless)
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                VStack(spacing: 4) {
                    rail(width: width)
                    waveform(width: width)
                    speakerLane(width: width)
                    ruler(width: width)
                }
                ForEach(editor.cuts) { cut in
                    Rectangle().fill(.orange)
                        .frame(width: 1.5, height: 91)
                        .offset(x: x(cut.time, width: width), y: 20)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    marker(cut, width: width)
                        .position(x: x(cut.time, width: width), y: 12)
                }
                Rectangle().fill(.primary)
                    .frame(width: 1.5, height: 60)
                    .offset(x: x(player.currentTime, width: width), y: 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(height: 119)
    }

    private func rail(width: Double) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let point = editor.hoveredCutPoint, draggedMarker == nil {
                HStack(spacing: 4) {
                    Image(systemName: "scissors").foregroundStyle(.orange)
                    Text(time(point)).font(.caption2.monospacedDigit())
                }
                .offset(x: min(max(0, x(point, width: width) - 10), max(0, width - 80)))
                .allowsHitTesting(false)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): editor.hover(at: seconds(location.x, width: width))
            case .ended: editor.hover(at: nil)
            }
        }
        .gesture(SpatialTapGesture().onEnded { editor.addCut(near: seconds($0.location.x, width: width)) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add cut")
        .accessibilityValue(editor.hoveredCutPoint.map(time) ?? "")
        .accessibilityAction { editor.addCut(near: editor.hoveredCutPoint ?? player.currentTime) }
        .accessibilityAdjustableAction { direction in
            let current = editor.hoveredCutPoint ?? player.currentTime
            let available = editor.cutPoints.filter { point in !editor.cuts.contains { $0.time == point } }
            editor.hoveredCutPoint = direction == .increment
                ? available.first { $0 > current } : available.last { $0 < current }
        }
    }

    private func waveform(width: Double) -> some View {
        Canvas { context, size in
            let values = peaks.isEmpty ? [Float](repeating: 0, count: 150) : peaks
            let step = size.width / Double(values.count)
            for (index, peak) in values.enumerated() {
                let height = max(2, Double(peak) * (size.height - 4))
                let rect = CGRect(x: Double(index) * step, y: (size.height - height) / 2,
                                  width: max(1, step - 1), height: height)
                let played = Double(index) / Double(values.count) < player.currentTime / max(editor.duration, 1)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(played ? .primary : .secondary.opacity(0.45)))
            }
            for index in editor.parts.indices where editor.parts[index].isDropped {
                let range = editor.range(at: index)
                let rect = CGRect(x: x(range.lowerBound, width: size.width), y: 0,
                                  width: x(range.upperBound - range.lowerBound, width: size.width), height: size.height)
                context.fill(Path(rect), with: .color(.gray.opacity(0.45)))
                var hatched = context
                hatched.clip(to: Path(rect))
                hatched.stroke(SpliceHatching().path(in: rect), with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            }
        }
        .frame(height: 60)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { player.seek(to: seconds($0.location.x, width: width)) })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording")
        .accessibilityValue(time(player.currentTime))
        .accessibilityAdjustableAction { direction in
            player.seek(to: max(0, min(editor.duration, player.currentTime + (direction == .increment ? 5 : -5))))
        }
    }

    private func speakerLane(width: Double) -> some View {
        Canvas { context, size in
            guard let transcript else { return }
            let speakers = TranscriptGrouper.displaySpeakers(of: transcript)
            for segment in transcript.segments where segment.startTime.isFinite && segment.endTime.isFinite && segment.endTime > segment.startTime {
                let start = max(0, Double(segment.startTime))
                let end = min(editor.duration, Double(segment.endTime))
                guard end > start else { continue }
                let color = speakers.first { $0.id == segment.speakerId }.flatMap { Color(hex: $0.colorHex) } ?? .secondary
                let dropped = editor.parts[editor.partIndex(at: start)].isDropped
                let rect = CGRect(x: x(start, width: size.width), y: 0, width: x(end - start, width: size.width), height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(dropped ? 0.25 : 0.9)))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func ruler(width: Double) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0..<5) { index in
                let value = editor.duration * Double(index) / 4
                Text(time(value))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: max(18, min(width - 18, width * Double(index) / 4)), y: 7)
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private func marker(_ cut: SpliceEditorViewModel.Cut, width: Double) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "scissors")
                .font(.caption.bold())
                .frame(width: 24, height: 24)
                .foregroundStyle(.white)
                .background(.orange, in: Circle())
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if draggedMarker == nil {
                            draggedMarker = cut.id
                            draggedStart = cut.time
                            editor.beginMovingCut(cut.id)
                        }
                        dragOffTimeline = abs(value.translation.height) > 60
                        editor.previewMove(near: draggedStart + seconds(value.translation.width, width: width, clamp: false))
                    }
                    .onEnded { _ in
                        editor.endMovingCut(remove: dragOffTimeline)
                        draggedMarker = nil
                        dragOffTimeline = false
                    })
                .accessibilityElement()
                .accessibilityLabel("Cut")
                .accessibilityValue(time(cut.time))
                .accessibilityAdjustableAction { direction in
                    let points = editor.cutPoints.filter { direction == .increment ? $0 > cut.time : $0 < cut.time }
                    if let next = direction == .increment ? points.first : points.last { editor.moveCut(cut.id, near: next) }
                }
                .accessibilityAction(named: "Remove cut") { editor.removeCut(cut.id) }
            Button { editor.removeCut(cut.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .background(.background, in: Circle())
            .opacity(hoveredMarker == cut.id ? 1 : 0)
            .accessibilityLabel("Remove cut")
        }
        .frame(width: 44)
        .offset(x: 10)
        .opacity(draggedMarker == cut.id && dragOffTimeline ? 0.35 : 1)
        .onHover { hoveredMarker = $0 ? cut.id : nil }
    }

    private var bands: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(Array(editor.parts.enumerated()), id: \.element.id) { index, part in
                    let range = editor.range(at: index)
                    let width = max(0, geometry.size.width - Double(editor.parts.count - 1) * 2) * (range.upperBound - range.lowerBound) / max(editor.duration, 1)
                    SplicePartBand(editor: editor, partID: part.id, index: index, width: width) {
                        player.seek(to: range.lowerBound)
                        player.play()
                    }
                    .frame(width: width)
                }
            }
        }
        .frame(height: 44)
    }

    private func time(_ seconds: Double) -> String { TimeFormatter.displayFormat(seconds: Float(seconds)) }
    private func x(_ time: Double, width: Double) -> Double { max(0, min(width, time / max(editor.duration, 1) * width)) }
    private func seconds(_ x: Double, width: Double, clamp: Bool = true) -> Double {
        let value = x / max(1, width) * editor.duration
        return clamp ? max(0, min(editor.duration, value)) : value
    }
}

struct SpliceHatching: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: rect.minX - rect.height, through: rect.maxX, by: 8) {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
        }
        return path
    }
}

struct SplicePartBand: View {
    let editor: SpliceEditorViewModel
    let partID: UUID
    let index: Int
    let width: Double
    let onPlay: () -> Void
    @FocusState private var isEditing: Bool
    @State private var name = ""
    @State private var isHovering = false
    private var dropped: Bool { editor.parts.first { $0.id == partID }?.isDropped ?? false }
    private var color: Color { dropped ? .gray : Self.color(index) }
    static func color(_ index: Int) -> Color { [.purple, .teal, .orange, .pink][index % 4] }

    var body: some View {
        HStack(spacing: 5) {
            if width > 35 {
                Button(action: onPlay) { Image(systemName: "play.fill").font(.system(size: 9)) }
                    .accessibilityLabel("Play part")
            }
            if width > 135 {
                VStack(alignment: .leading, spacing: 2) {
                    if dropped { Text("Dropped").font(.caption.weight(.semibold)) }
                    else {
                        TextField("", text: $name)
                            .textFieldStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .focused($isEditing)
                            .accessibilityLabel("Part name")
                            .onSubmit { commitName(); isEditing = false }
                            .onChange(of: isEditing) { _, focused in if !focused { commitName() } }
                    }
                    Text(TimeFormatter.displayFormat(seconds: Float(length)))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if width > 50 {
                Button { editor.toggleDropped(partID) } label: {
                    Image(systemName: dropped ? "plus.circle" : "minus.circle")
                }
                .help(dropped ? "Keep this part" : "Drop this part")
                .accessibilityLabel(dropped ? "Keep this part" : "Drop this part")
                .opacity(dropped || isHovering ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, width > 60 ? 9 : 2)
        .frame(maxWidth: .infinity, minHeight: 44)
        .foregroundStyle(color)
        .background(color.opacity(0.13))
        .overlay { if dropped { SpliceHatching().stroke(.secondary.opacity(0.15), lineWidth: 1).allowsHitTesting(false) } }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovering = $0 }
        .onAppear { name = editor.title(at: index) }
        .onChange(of: editor.title(at: index)) { _, value in if !isEditing { name = value } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(dropped ? "Dropped" : editor.title(at: index))
        .accessibilityValue(SpliceCopy.length(length))
        .accessibilityAction(named: dropped ? "Keep this part" : "Drop this part") { editor.toggleDropped(partID) }
    }

    private var length: Double { let range = editor.range(at: index); return range.upperBound - range.lowerBound }
    private func commitName() { editor.renamePart(partID, to: name) }
}
