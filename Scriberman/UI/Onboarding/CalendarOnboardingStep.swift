import SwiftUI

/// Optional step: offers calendar meeting suggestions. Either answer completes onboarding.
struct CalendarOnboardingStep: View {
    @Environment(AppState.self) private var appState
    var onAdvance: () -> Void

    @State private var isResolving = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)

            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Upcoming Meetings")
                .font(.title2.weight(.semibold))

            Text("Suggest recording sessions from calendars connected to your Mac? You can turn this off in Settings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)

            Button {
                resolve(enable: true)
            } label: {
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Text("Enable calendar suggestions")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isResolving)

            Button("Not now") {
                resolve(enable: false)
            }
            .buttonStyle(.bordered)
            .disabled(isResolving)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            appState.markCalendarInvitationPresented()
        }
    }

    private func resolve(enable: Bool) {
        guard !isResolving else { return }
        isResolving = true
        Task {
            await appState.resolveCalendarInvitation(enable: enable)
            isResolving = false
            onAdvance()
        }
    }
}
