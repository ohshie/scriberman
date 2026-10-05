import SwiftUI

/// The field a speaker is renamed in, with suggestions from speaker memory below it.
///
/// Opens focused with its text selected. Return commits the highlighted suggestion, or the text
/// when there are none; Escape or moving focus away cancels.
struct SpeakerNameField: View {
    let profiles: [SpeakerProfileSnapshot]
    var color: Color = .primary
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var selection: TextSelection?
    @State private var highlighted = 0
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    init(
        name: String,
        profiles: [SpeakerProfileSnapshot],
        color: Color = .primary,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.profiles = profiles
        self.color = color
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._text = State(initialValue: name)
        self._selection = State(initialValue: TextSelection(range: name.startIndex..<name.endIndex))
    }

    private var rows: [SpeakerNameSuggestions.Row] {
        SpeakerNameSuggestions.rows(for: text, profiles: profiles)
    }

    var body: some View {
        TextField("Speaker Name", text: $text, selection: $selection)
            .textFieldStyle(.roundedBorder)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 180)
            .focused($isFocused)
            .onSubmit { commit(rows.indices.contains(highlighted) ? rows[highlighted].name : text) }
            .onExitCommand { cancel() }
            .onKeyPress(.downArrow) {
                guard !rows.isEmpty else { return .ignored }
                highlighted = min(highlighted + 1, rows.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !rows.isEmpty else { return .ignored }
                highlighted = max(highlighted - 1, 0)
                return .handled
            }
            .onChange(of: text) { highlighted = 0 }
            .onChange(of: isFocused) {
                if !isFocused { cancel() }
            }
            .task { isFocused = true }
            .overlay(alignment: .topLeading) {
                if !rows.isEmpty {
                    suggestionList
                        .offset(y: 28)
                }
            }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                suggestionRow(row, isHighlighted: index == highlighted)
                    .contentShape(Rectangle())
                    .onTapGesture { commit(row.name) }
                    .onHover { if $0 { highlighted = index } }
            }
        }
        .padding(5)
        .frame(width: 250, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private func suggestionRow(_ row: SpeakerNameSuggestions.Row, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            switch row {
            case .profile(let name, let count):
                Text(name)
                Spacer(minLength: 8)
                Text(count, format: .number)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            case .newProfile(let name):
                Image(systemName: "plus")
                    .font(.caption)
                Text("new profile “\(name)”")
                Spacer(minLength: 0)
            }
        }
        .font(.subheadline)
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHighlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func commit(_ name: String) {
        guard !isFinished else { return }
        isFinished = true
        onCommit(name)
    }

    private func cancel() {
        guard !isFinished else { return }
        isFinished = true
        onCancel()
    }
}
