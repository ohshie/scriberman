import SwiftUI

/// The hidden Dev Features tab in Settings, shown only while `DeveloperSettings` is unlocked.
struct DevFeaturesSettingsView: View {
    var settings: DeveloperSettings

    /// A flag's label and caption. A new flag is listed by adding its definition and one entry here.
    private struct FlagCopy {
        let flag: KeyPath<AudioSyncConfig.FlagDefinitions, AudioSyncConfig.Flag>
        let title: String
        let caption: String
    }

    private static let audioSyncFlags = [
        FlagCopy(
            flag: \.timelineMixdown,
            title: "Timeline mixdown",
            caption: "Aligns mic and app audio by capture timestamps when mixing."
        ),
        FlagCopy(
            flag: \.unifiedCapture,
            title: "Unified capture",
            caption: "Records mic and app audio from one stream. macOS 15 or later."
        ),
        FlagCopy(
            flag: \.captureHealthRecovery,
            title: "Capture health recovery",
            caption: "Restarts capture if it stops during a recording."
        ),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.audioSyncFlags, id: \.flag) { copy in
                    let flag = settings.flagDefinitions[keyPath: copy.flag]
                    VStack(alignment: .leading) {
                        Toggle(copy.title, isOn: Binding(
                            get: { settings.isOn(flag) },
                            set: { settings.set(flag, isOn: $0) }
                        ))
                        Text(copy.caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Audio Sync")
            } footer: {
                Text("Changes apply from the next recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Hide Dev Features") {
                    settings.hide()
                }
            }
        }
        .formStyle(.grouped)
    }
}
