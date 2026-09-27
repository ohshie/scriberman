import Foundation
import Testing
@testable import Scriberman

struct MeetingLinkMatcherTests {
    private func service(_ string: String) -> MeetingLinkMatcher.Service? {
        URL(string: string).flatMap(MeetingLinkMatcher.service(for:))
    }

    @Test(arguments: [
        ("https://zoom.us/j/123456789", MeetingLinkMatcher.Service.zoom),
        ("https://us02web.zoom.us/j/123456789?pwd=abc", .zoom),
        ("https://company.zoom.us/my/room", .zoom),
        ("https://ZOOM.US/j/1", .zoom),
        ("https://meet.google.com/abc-defg-hij", .googleMeet),
        ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0", .microsoftTeams),
        ("https://teams.microsoft.com/meet/123?p=abc", .microsoftTeams),
        ("https://teams.live.com/meet/9876", .microsoftTeams),
    ])
    func acceptedLinks(url: String, expected: MeetingLinkMatcher.Service) {
        #expect(service(url) == expected)
    }

    @Test(arguments: [
        // Homepages and paths outside the agreed boundaries.
        "https://zoom.us",
        "https://zoom.us/",
        "https://zoom.us/j/",
        "https://zoom.us/signin",
        "https://meet.google.com",
        "https://meet.google.com/",
        "https://teams.microsoft.com",
        "https://teams.microsoft.com/l/meetup-join/",
        "https://teams.microsoft.com/meet/",
        // Scheme.
        "http://zoom.us/j/123",
        "zoommtg://zoom.us/join?confno=123",
        // Impersonating or unsupported hosts.
        "https://zoom.us.example.com/j/123",
        "https://evilzoom.us/j/123",
        "https://zoom.us@example.com/j/123",
        "https://example.com/zoom.us/j/123",
        "https://meet.google.com.example.com/abc-defg-hij",
        "https://google.com/meet/abc",
        "https://teams.microsoft.com.example.com/meet/1",
        "https://teams.microsoft.us/meet/1",
        "https://gov.teams.microsoft.us/l/meetup-join/1",
        // Wrapped links.
        "https://safelinks.protection.outlook.com/?url=https%3A%2F%2Fzoom.us%2Fj%2F123",
    ])
    func rejectedLinks(url: String) {
        #expect(service(url) == nil)
    }

    @Test("A link in the notes qualifies the event")
    func linkInNotes() {
        let event = CalendarEventSnapshot.fixture(
            start: .now,
            url: nil,
            notes: "Agenda attached.\nJoin: https://meet.google.com/abc-defg-hij\nThanks"
        )
        #expect(MeetingLinkMatcher.service(for: event) == .googleMeet)
    }

    @Test("A link in the location qualifies the event")
    func linkInLocation() {
        let event = CalendarEventSnapshot.fixture(
            start: .now,
            url: nil,
            location: "Microsoft Teams Meeting https://teams.microsoft.com/l/meetup-join/abc"
        )
        #expect(MeetingLinkMatcher.service(for: event) == .microsoftTeams)
    }

    @Test("Service names without a link do not qualify")
    func serviceNamesOnly() {
        let event = CalendarEventSnapshot.fixture(
            start: .now,
            url: nil,
            location: "Zoom",
            notes: "Let's meet on Teams or Google Meet. zoom.us/j/123 meet.google.com/abc"
        )
        #expect(MeetingLinkMatcher.service(for: event) == nil)
    }

    @Test("A malformed or unsupported event URL falls through to the notes")
    func unsupportedURLFallsThrough() {
        let event = CalendarEventSnapshot.fixture(
            start: .now,
            url: URL(string: "https://example.com/event"),
            notes: "https://zoom.us/j/42"
        )
        #expect(MeetingLinkMatcher.service(for: event) == .zoom)
    }
}
