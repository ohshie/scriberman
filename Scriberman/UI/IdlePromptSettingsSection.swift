import SwiftUI

/// Settings group for the idle session prompt: which sources are watched, how they combine,
/// when to ask, and whether to stop automatically.
struct IdlePromptSettingsSection: View {
    @Bindable var preferences: IdlePromptPreferences

    private var isCombinationRuleEnabled: Bool {
        preferences.watchedSourceCount >= 2
    }

    var body: some View {
        Section("Idle Session Prompt") {
            Toggle("Ask to stop when a meeting looks finished", isOn: $preferences.isEnabled)
            Text("Applies only to recordings that capture both microphone and app audio.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Group {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watch for activity from")
                        .foregroundStyle(.secondary)
                    Toggle("App audio", isOn: $preferences.watchAppAudio)
                    Toggle("Microphone", isOn: $preferences.watchMicAudio)
                    Toggle("Mouse & keyboard", isOn: $preferences.watchUserInput)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(isCombinationRuleEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Picker("Ask when", selection: $preferences.requiresAllSourcesIdle) {
                        Text("all selected sources are idle").tag(true)
                        Text("any selected source is idle").tag(false)
                    }
                    .labelsHidden()
                    .disabled(!isCombinationRuleEnabled)
                }

                Picker("Ask after", selection: $preferences.idleThresholdMinutes) {
                    ForEach(IdlePromptPreferences.selectableMinutes, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }

                Toggle("Stop automatically if ignored", isOn: $preferences.autoStopEnabled)
                Picker("Stop after", selection: $preferences.autoStopDelayMinutes) {
                    ForEach(IdlePromptPreferences.selectableMinutes, id: \.self) { minutes in
                        Text("\(minutes) minutes").tag(minutes)
                    }
                }
                .disabled(!preferences.autoStopEnabled)
            }
            .disabled(!preferences.isEnabled)
        }
    }
}
