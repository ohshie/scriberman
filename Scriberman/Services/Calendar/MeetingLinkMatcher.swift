import Foundation

/// Decides whether an event carries a supported online-meeting link.
///
/// Only HTTPS links whose parsed host and path match the rules below qualify. Hosts are compared
/// exactly or by dot-delimited suffix, never by substring, so `zoom.us.example.com` and
/// `https://zoom.us@example.com/j/1` do not match. Links are never fetched or followed.
///
/// | Service         | Host                                      | Path                                   |
/// | --------------- | ----------------------------------------- | -------------------------------------- |
/// | Zoom            | `zoom.us` or `*.zoom.us`                  | `/j/<x>` or `/my/<x>`                  |
/// | Google Meet     | `meet.google.com`                         | `/<x>`                                 |
/// | Microsoft Teams | `teams.microsoft.com`, `teams.live.com`   | `/l/meetup-join/<x>` or `/meet/<x>`    |
enum MeetingLinkMatcher {
    enum Service: Equatable, Sendable {
        case zoom
        case googleMeet
        case microsoftTeams
    }

    static func service(for event: CalendarEventSnapshot) -> Service? {
        if let url = event.url, let service = service(for: url) {
            return service
        }
        for text in [event.location, event.notes].compactMap(\.self) {
            for url in links(in: text) {
                if let service = service(for: url) {
                    return service
                }
            }
        }
        return nil
    }

    static func service(for url: URL) -> Service? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            return path.count >= 2 && ["j", "my"].contains(path[0]) ? .zoom : nil
        }
        if host == "meet.google.com" {
            return path.isEmpty ? nil : .googleMeet
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            if path.count >= 3, path[0] == "l", path[1] == "meetup-join" { return .microsoftTeams }
            if path.count >= 2, path[0] == "meet" { return .microsoftTeams }
            return nil
        }
        return nil
    }

    /// Links written with an explicit `https://` in free text. Bare hostnames are not links here.
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap { match in
            guard let url = match.url, let matchRange = Range(match.range, in: text),
                  text[matchRange].lowercased().hasPrefix("https://") else {
                return nil
            }
            return url
        }
    }
}
