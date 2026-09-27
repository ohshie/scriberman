import AppKit
import SwiftUI

/// General Settings group for calendar meeting suggestions: enablement, access remediation and
/// which calendars are read.
struct CalendarSettingsSection: View {
    var controller: CalendarSuggestionController

    private var preferences: CalendarSuggestionPreferences {
        controller.preferences
    }

    private var hasNoSelectedCalendar: Bool {
        preferences.selectedCalendarIDs.isDisjoint(with: controller.calendars.map(\.id))
    }

    var body: some View {
        Section("Calendar") {
            HStack {
                Toggle(
                    "Enable calendar suggestions",
                    isOn: Binding(
                        get: { preferences.isEnabled || controller.isRequestingAccess },
                        set: { enabled in Task { await controller.setEnabled(enabled) } }
                    )
                )
                if controller.isRequestingAccess {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            switch controller.authorizationStatus {
            case .denied, .restricted:
                Text("Scriberman doesn't have calendar access. Allow it in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    openCalendarPrivacySettings()
                }
            case .fullAccess:
                calendarSelection
            case .notDetermined:
                EmptyView()
            }

            if controller.refreshFailed || controller.calendarListState == .failed {
                HStack {
                    Text("Couldn't read your calendars.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task {
                            await controller.loadCalendars()
                            await controller.refresh()
                        }
                    }
                }
            }
        }
        .task {
            await controller.loadCalendars()
        }
    }

    @ViewBuilder
    private var calendarSelection: some View {
        if controller.calendarListState == .loaded {
            if controller.calendars.isEmpty {
                Text("No calendars found. Add an account in System Settings > Internet Accounts, then select its calendars here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calendars")
                        .foregroundStyle(.secondary)
                    ForEach(controller.calendars) { calendar in
                        Toggle(isOn: Binding(
                            get: { preferences.selectedCalendarIDs.contains(calendar.id) },
                            set: { controller.setCalendar(calendar.id, selected: $0) }
                        )) {
                            HStack(spacing: 6) {
                                Text(calendar.title)
                                Text(calendar.sourceTitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if hasNoSelectedCalendar {
                    Text("Select at least one calendar to get suggestions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
