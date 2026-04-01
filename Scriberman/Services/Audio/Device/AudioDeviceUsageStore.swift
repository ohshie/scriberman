import Foundation

final class AudioDeviceUsageStore {
    private let userDefaults: UserDefaults
    private let key: String
    private var scores: [String: Int]

    init(userDefaults: UserDefaults = .standard, key: String = "deviceUsageScores") {
        self.userDefaults = userDefaults
        self.key = key
        self.scores = Self.loadScores(from: userDefaults, key: key)
    }

    func increment(uid: String) {
        guard !uid.isEmpty else {
            return
        }

        scores[uid, default: 0] += 1
        persistScores()
    }

    func sort(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        devices.sorted { lhs, rhs in
            let lhsUsage = scores[lhs.uid, default: 0]
            let rhsUsage = scores[rhs.uid, default: 0]
            if lhsUsage != rhsUsage {
                return lhsUsage > rhsUsage
            }

            let nameCompare = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameCompare != .orderedSame {
                return nameCompare == .orderedAscending
            }

            return lhs.uid < rhs.uid
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
