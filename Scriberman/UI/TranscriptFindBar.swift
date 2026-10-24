import Observation
import SwiftUI

struct TranscriptFindBar: View {
    @Bindable var searchState: TranscriptSearchState
    let onDismiss: () -> Void

    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find in transcript", text: $searchState.query)
                .textFieldStyle(.plain)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    searchState.next()
                }

            if searchState.query.isEmpty == false {
                if searchState.matches.isEmpty {
                    Text("No results")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(searchState.summary)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        searchState.previous()
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous match")
                    .help("Previous match")

                    Button {
                        searchState.next()
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next match")
                    .help("Next match")
                }
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close find")
            .help("Close find")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        // Only while focus is inside the bar: a shortcut was window-wide and took Escape from the
        // session search field.
        .onExitCommand {
            onDismiss()
        }
        .onAppear {
            isSearchFieldFocused = true
        }
    }
}
