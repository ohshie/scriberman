import Foundation

/// The rows the speaker rename field suggests for the text typed so far.
enum SpeakerNameSuggestions {
    enum Row: Equatable, Hashable {
        /// A stored profile, with its voiceprint count.
        case profile(name: String, count: Int)
        /// A profile that committing would create, named by the typed text.
        case newProfile(name: String)

        /// The name committing this row renames the speaker to.
        var name: String {
            switch self {
            case .profile(let name, _), .newProfile(let name): name
            }
        }
    }

    /// Profiles in the current voiceprint space whose names contain `text` case-insensitively, in
    /// the order given, then a new-profile row unless one of them is named `text`. Empty for text
    /// that is empty after trimming whitespace.
    static func rows(for text: String, profiles: [SpeakerProfileSnapshot]) -> [Row] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        let query = typed.lowercased()
        let matches = profiles.filter {
            $0.voiceprintSpace == VoiceprintSpace.current && $0.name.lowercased().contains(query)
        }
        var rows = matches.map { Row.profile(name: $0.name, count: $0.sampleCount) }
        if !matches.contains(where: { $0.name.lowercased() == query }) {
            rows.append(.newProfile(name: typed))
        }
        return rows
    }
}
