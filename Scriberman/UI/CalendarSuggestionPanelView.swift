import SwiftUI

/// Content of the floating meeting-suggestion panel: one row per eligible meeting, in start
/// order. Styled like the idle session prompt.
struct CalendarSuggestionPanelView: View {
    let suggestions: [CalendarMeetingSuggestion]
    let onPrepare: (CalendarOccurrenceID) -> Void
    let onDismiss: (CalendarOccurrenceID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 10) {
                    Text(Self.headline(for: suggestion))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button("Prepare session") {
                            onPrepare(suggestion.id)
                        }
                        .buttonStyle(.bordered)

                        Button("Dismiss") {
                            onDismiss(suggestion.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .frame(width: 280, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        }
    }

    static func headline(for suggestion: CalendarMeetingSuggestion) -> String {
        let time = suggestion.start.formatted(date: .omitted, time: .shortened)
        let title = suggestion.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty
            ? "Meeting at \(time). Prepare session?"
            : "\(title) at \(time). Prepare session?"
    }
}
