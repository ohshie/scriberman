import Foundation
import Observation

@MainActor
@Observable
final class SpliceEditorViewModel {
    struct Cut: Identifiable, Equatable {
        let id: UUID
        var time: Double
    }
    struct Part: Identifiable, Equatable {
        let id: UUID
        var customTitle: String?
        var isDropped = false
    }
    private struct State: Equatable {
        var cuts: [Cut] = []
        var parts = [Part(id: UUID())]
    }

    let originalTitle: String
    let duration: Double
    let cutPoints: [Double]
    let transcriptFingerprint: Data
    let undoManager = UndoManager()
    private var state = State()
    private var dragStart: State?
    private var draggingID: UUID?
    private var historyRevision = 0
    var hoveredCutPoint: Double?
    var isApplying = false

    init(title: String, duration: Double, transcript: Transcript?, retranscript: Transcript?, fingerprint: Data) {
        originalTitle = title
        self.duration = duration
        transcriptFingerprint = fingerprint
        cutPoints = SpliceService.cutPoints(transcript: transcript, retranscript: retranscript, duration: duration)
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 100
    }

    var cuts: [Cut] { state.cuts }
    var parts: [Part] { state.parts }
    var keptCount: Int { parts.filter { !$0.isDropped }.count }
    var canApply: Bool { !isApplying && dragStart == nil && !cuts.isEmpty && keptCount > 0 }
    var canUndo: Bool { _ = historyRevision; return !isApplying && dragStart == nil && undoManager.canUndo }
    var canRedo: Bool { _ = historyRevision; return !isApplying && dragStart == nil && undoManager.canRedo }
    var plan: SplicePlan {
        SplicePlan(cuts: cuts.map(\.time), parts: parts.indices.map {
            .init(title: title(at: $0), isDropped: parts[$0].isDropped)
        }, transcriptFingerprint: transcriptFingerprint)
    }

    func range(at index: Int) -> Range<Double> {
        guard parts.indices.contains(index) else { return 0..<0 }
        let start = index == 0 ? 0 : cuts[index - 1].time
        let end = index == cuts.count ? duration : cuts[index].time
        return start..<end
    }

    func title(at index: Int) -> String {
        guard parts.indices.contains(index) else { return originalTitle }
        if let title = parts[index].customTitle { return title }
        if index == parts.firstIndex(where: { !$0.isDropped }) { return originalTitle }
        return "\(originalTitle) (Part \(index + 1))"
    }

    func partIndex(at time: Double) -> Int {
        guard time.isFinite else { return 0 }
        return cuts.firstIndex(where: { time < $0.time }) ?? cuts.count
    }

    func nearestFreePoint(to time: Double, moving id: UUID? = nil) -> Double? {
        guard time.isFinite else { return nil }
        let index = id.flatMap { id in cuts.firstIndex { $0.id == id } }
        let lower = index.map { $0 == 0 ? 0 : cuts[$0 - 1].time } ?? 0
        let upper = index.map { $0 == cuts.count - 1 ? duration : cuts[$0 + 1].time } ?? duration
        let occupied = Set(cuts.filter { $0.id != id }.map(\.time))
        return cutPoints.filter { !occupied.contains($0) && $0 > lower && $0 < upper }
            .min { abs($0 - time) < abs($1 - time) }
    }

    func hover(at time: Double?) {
        hoveredCutPoint = time.flatMap { nearestFreePoint(to: $0) }
    }

    func addCut(near time: Double) {
        guard !isApplying, dragStart == nil, let point = nearestFreePoint(to: time) else { return }
        let index = cuts.firstIndex(where: { $0.time > point }) ?? cuts.count
        edit(named: "Add Cut") {
            $0.cuts.insert(Cut(id: UUID(), time: point), at: index)
            $0.parts.insert(Part(id: UUID()), at: index + 1)
        }
        hoveredCutPoint = nil
    }

    func removeCut(_ id: UUID) {
        guard !isApplying, dragStart == nil, let index = cuts.firstIndex(where: { $0.id == id }) else { return }
        edit(named: "Remove Cut") {
            $0.cuts.remove(at: index)
            $0.parts.remove(at: index + 1)
        }
    }

    func moveCut(_ id: UUID, near time: Double) {
        guard !isApplying, dragStart == nil, let point = nearestFreePoint(to: time, moving: id),
              let index = cuts.firstIndex(where: { $0.id == id }), point != cuts[index].time else { return }
        edit(named: "Move Cut") { $0.cuts[index].time = point }
    }

    func beginMovingCut(_ id: UUID) {
        guard !isApplying, dragStart == nil, cuts.contains(where: { $0.id == id }) else { return }
        dragStart = state
        draggingID = id
        hoveredCutPoint = nil
    }

    func previewMove(near time: Double) {
        guard let id = draggingID, let index = cuts.firstIndex(where: { $0.id == id }),
              let point = nearestFreePoint(to: time, moving: id) else { return }
        state.cuts[index].time = point
    }

    func endMovingCut(remove: Bool = false) {
        guard let before = dragStart, let id = draggingID else { return }
        let after = state
        dragStart = nil
        draggingID = nil
        state = before
        if remove { removeCut(id) }
        else if before != after { replace(with: after, named: "Move Cut") }
    }

    func renamePart(_ id: UUID, to title: String) {
        guard !isApplying, let index = parts.firstIndex(where: { $0.id == id }), title != self.title(at: index) else { return }
        edit(named: "Part Name") { $0.parts[index].customTitle = title }
    }

    func toggleDropped(_ id: UUID) {
        guard !isApplying, let index = parts.firstIndex(where: { $0.id == id }) else { return }
        edit(named: parts[index].isDropped ? "Keep Part" : "Drop Part") { $0.parts[index].isDropped.toggle() }
    }

    func undo() {
        guard canUndo else { return }
        undoManager.undo()
        historyRevision += 1
    }

    func redo() {
        guard canRedo else { return }
        undoManager.redo()
        historyRevision += 1
    }

    func discardHistory() {
        undoManager.removeAllActions()
        historyRevision += 1
    }

    private func edit(named name: String, _ mutate: (inout State) -> Void) {
        var next = state
        mutate(&next)
        if next != state { replace(with: next, named: name) }
    }

    private func replace(with next: State, named name: String) {
        let previous = state
        let needsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if needsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            target.replace(with: previous, named: name)
        }
        undoManager.setActionName(name)
        if needsGroup { undoManager.endUndoGrouping() }
        state = next
        historyRevision += 1
    }
}

/// Remembers whether the selected recording's transcripts allow a cut. Command availability is
/// rebuilt often, and the answer needs both passes decoded, so it is recomputed only when the
/// session, its duration or its raw pass bytes change.
@MainActor
final class SpliceCutPointCache {
    private struct Key: Equatable {
        let sessionID: UUID
        let duration: Double
        let fingerprint: Data
    }

    private var key: Key?
    private var value = false
    private(set) var computeCount = 0

    func hasCutPoint(_ session: RecordingSession) -> Bool {
        guard session.mixdownURL != nil, session.transcriptData != nil || session.retranscriptData != nil else { return false }
        let key = Key(
            sessionID: session.id, duration: session.duration,
            fingerprint: SplicePlan.fingerprint(transcriptData: session.transcriptData, retranscriptData: session.retranscriptData)
        )
        if key == self.key { return value }
        computeCount += 1
        self.key = key
        value = session.displayedTranscript != nil && !SpliceService.cutPoints(
            transcript: session.transcript, retranscript: session.retranscript, duration: session.duration
        ).isEmpty
        return value
    }
}
