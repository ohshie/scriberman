import Foundation

@MainActor
final class AppAudioUsageStore {
    private let userDefaults: UserDefaults
    private let key: String
    private var scores: [String: Int]

    init(userDefaults: UserDefaults = .standard, key: String = "appAudioUsageScores") {
        self.userDefaults = userDefaults
        self.key = key
        self.scores = Self.loadScores(from: userDefaults, key: key)
    }

    func increment(bundleID: String) {
        guard !bundleID.isEmpty else {
            return
        }

        scores[bundleID, default: 0] += 1
        persistScores()
    }

    func sort(_ apps: [CapturedApp]) -> [CapturedApp] {
        apps.sorted { lhs, rhs in
            let lhsUsage = scores[lhs.bundleID, default: 0]
            let rhsUsage = scores[rhs.bundleID, default: 0]
            if lhsUsage != rhsUsage {
                return lhsUsage > rhsUsage
            }

            let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }

            return lhs.bundleID < rhs.bundleID
        }
    }

    private func persistScores() {
        userDefaults.set(scores, forKey: key)
    }

    private static func loadScores(from userDefaults: UserDefaults, key: String) -> [String: Int] {
        guard let rawScores = userDefaults.dictionary(forKey: key) else {
            return [:]
        }

        return rawScores.reduce(into: [String: Int]()) { result, entry in
            if let value = entry.value as? Int {
                result[entry.key] = value
                return
            }
            if let value = entry.value as? NSNumber {
                result[entry.key] = value.intValue
            }
        }
    }
}
