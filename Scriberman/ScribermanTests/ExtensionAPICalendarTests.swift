import Foundation
import SwiftData
import Testing
@testable import Scriberman

/// The calendar routes, driven through signed requests to the handler with a real calendar
/// suggestion controller over the mock calendar service, and the recording fixture's real capture
/// coordinator.
@MainActor
struct ExtensionAPICalendarTests {
    // MARK: - Fixture

    @MainActor
    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    @MainActor
    final class Fixture {
        let recording: ExtensionAPIRecordingTests.Fixture
        let calendarService = MockCalendarService(status: .fullAccess)
        let clock: Clock
        let controller: CalendarSuggestionController
        let work = CalendarSnapshot(id: "work", title: "Work", sourceTitle: "iCloud")
        private let suiteName = "ExtensionAPICalendarTests-\(UUID().uuidString)"

        init(now: Date) throws {
            recording = try ExtensionAPIRecordingTests.Fixture()
            let clock = Clock(now)
            self.clock = clock
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            controller = CalendarSuggestionController(
                service: calendarService,
                preferences: CalendarSuggestionPreferences(userDefaults: defaults),
                now: { clock.now },
                // Timers never fire on their own; the tests move the clock.
                sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
                workspaceNotificationCenter: NotificationCenter(),
                notificationCenter: NotificationCenter()
            )
            calendarService.update { $0.calendars = [work] }
            let recordingRoutes = try #require(recording.api.handler.recording)
            recording.api.handler.calendar = ExtensionAPICalendar(controller: controller, recording: recordingRoutes)
        }

        deinit {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        func setEvents(_ events: [CalendarEventSnapshot]) {
            calendarService.update { $0.events = events }
        }

        /// Activates the controller and turns suggestions on, as a ready app with the feature on.
        func enableSuggestions() async {
            controller.activate()
            await controller.setEnabled(true)
            await controller.refresh()
        }

        func send(_ method: String, _ target: String, json: String? = nil) async -> HTTPResponse {
            await recording.send(method, target, json: json)
        }

        func suggestions() async throws -> SuggestionsBody {
            let response = await send("GET", "/v1/calendar/suggestions")
            #expect(response.status == 200)
            return try JSONDecoder().decode(SuggestionsBody.self, from: response.body)
        }
    }

    // MARK: - Bodies

    struct SuggestionBody: Decodable, Equatable {
        let occurrenceId: String
        let title: String
        let start: String
        let end: String
    }

    struct SuggestionsBody: Decodable {
        let suggestions: [SuggestionBody]
        let suggestionsEnabled: Bool
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func date(_ text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }

    private func errorCode(_ response: HTTPResponse) -> String? {
        struct ErrorBody: Decodable { let code: String }
        return try? JSONDecoder().decode(ErrorBody.self, from: response.body).code
    }

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        try JSONDecoder().decode(type, from: response.body)
    }

    // MARK: - Suggestions

    @Test
    func suggestionsMatchTheControllersForTheSameCalendarState() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([
            .fixture(itemID: "standup", title: "Standup", start: now.addingTimeInterval(60), duration: 15 * 60),
            .fixture(itemID: "review", title: "Design review", start: now.addingTimeInterval(-3 * 60)),
            // Starts in an hour: outside the window.
            .fixture(itemID: "later", title: "Later", start: now.addingTimeInterval(3_600)),
            // No meeting link.
            .fixture(itemID: "lunch", title: "Lunch", start: now, url: nil),
            // Declined.
            .fixture(itemID: "declined", title: "Declined", start: now, selfResponse: .declined),
        ])
        await fixture.enableSuggestions()

        let body = try await fixture.suggestions()

        #expect(body.suggestionsEnabled)
        let expected = fixture.controller.visibleSuggestions
        #expect(expected.count == 2)
        #expect(body.suggestions.map(\.title) == expected.map(\.title))
        #expect(body.suggestions.map { date($0.start) } == expected.map(\.start))
        #expect(body.suggestions.map(\.title) == ["Design review", "Standup"])
        #expect(body.suggestions.map(\.end) == [iso(now.addingTimeInterval(27 * 60)), iso(now.addingTimeInterval(16 * 60))])
        #expect(Set(body.suggestions.map(\.occurrenceId)).count == 2)
        #expect(body.suggestions.allSatisfy { !$0.occurrenceId.isEmpty })
    }

    @Test
    func suggestionsFollowTheClock() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()

        fixture.clock.now = now.addingTimeInterval(6 * 60)
        let body = try await fixture.suggestions()

        #expect(body.suggestionsEnabled)
        #expect(body.suggestions.isEmpty)
    }

    @Test
    func suggestionsAreOffWhenTheFeatureIsOff() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        fixture.controller.activate()

        let body = try await fixture.suggestions()

        #expect(!body.suggestionsEnabled)
        #expect(body.suggestions.isEmpty)
    }

    @Test
    func suggestionsAreOffBeforeTheAppIsReady() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.controller.setEnabled(true)

        let body = try await fixture.suggestions()

        #expect(!body.suggestionsEnabled)
        #expect(body.suggestions.isEmpty)
    }

    @Test
    func suggestionsAreOffWhenCalendarAccessWasWithdrawn() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()
        fixture.calendarService.update { $0.status = .denied }

        let body = try await fixture.suggestions()

        #expect(!body.suggestionsEnabled)
        #expect(body.suggestions.isEmpty)
    }

    // MARK: - Start from a suggestion

    @Test
    func startTakesTheMeetingTitleAndTheGivenCaptureFields() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.recording.audioDeviceService.availableDevices = [AudioInputDevice(id: 4, uid: "mic-usb", name: "USB Mic")]
        fixture.recording.appAudioService.runningApps = [CapturedApp(bundleID: "com.example.call", name: "Call", pid: 40, icon: nil)]
        fixture.recording.screenCaptureService.availableDisplays = [CaptureDisplay(displayID: 77, name: "Studio", width: 5120, height: 2880)]
        let tag = try fixture.recording.tag("Client")
        fixture.setEvents([.fixture(title: "  Design review  ", start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)", "microphoneUid": "mic-usb",
             "appBundleId": "com.example.call", "screen": true, "displayId": 77, "tagIds": ["\(tag.id.uuidString)"]}
            """)

        #expect(response.status == 200)
        let body = try decode(ExtensionAPIRecordingTests.StartBody.self, response)
        #expect(body.session.title == "Design review")
        #expect(body.session.tags == [.init(id: tag.id.uuidString, name: "Client")])
        #expect(body.capture == .init(microphoneUid: "mic-usb", appBundleId: "com.example.call", displayId: 77))
        let call = try #require(fixture.recording.recordingService.startCalls.first)
        #expect(call.micDeviceID == 4)
        #expect(call.appProcessID == 40)
        #expect(call.captureDisplayID == 77)
        let session = try #require(try fixture.recording.persistedSessions().first)
        #expect(session.title == "Design review")
        #expect(body.session.id == "recording:\(session.id.uuidString)")
        #expect(fixture.recording.requestedSessions == [.recording(session.id)])
    }

    @Test
    func startWithOnlyAnOccurrenceRecordsTheDefaultMicrophone() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(title: "Standup", start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)"}
            """)

        #expect(response.status == 200)
        let body = try decode(ExtensionAPIRecordingTests.StartBody.self, response)
        #expect(body.session.title == "Standup")
        #expect(body.capture == .init(microphoneUid: nil, appBundleId: nil, displayId: nil))
        #expect(fixture.recording.recordingService.startCalls.count == 1)
    }

    @Test
    func aTitleInTheBodyDoesNotReplaceTheMeetingTitle() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(title: "Standup", start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)", "title": "Other"}
            """)

        #expect(response.status == 200)
        #expect(try decode(ExtensionAPIRecordingTests.StartBody.self, response).session.title == "Standup")
    }

    @Test
    func aBlankMeetingTitleGivesTheDraftSessionTitle() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(title: "   ", start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)"}
            """)

        #expect(response.status == 200)
        let title = try decode(ExtensionAPIRecordingTests.StartBody.self, response).session.title
        #expect(title.hasPrefix("Session "))
        #expect(title != CaptureCoordinator.quickStartTitle)
    }

    @Test
    func afterAStartTheOccurrenceIsNoLongerSuggested() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([
            .fixture(itemID: "review", title: "Design review", start: now),
            .fixture(itemID: "standup", title: "Standup", start: now),
        ])
        await fixture.enableSuggestions()
        let review = try #require(try await fixture.suggestions().suggestions.first { $0.title == "Design review" })

        let started = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(review.occurrenceId)"}
            """)
        #expect(started.status == 200)
        _ = await fixture.send("POST", "/v1/recordings/stop")

        let body = try await fixture.suggestions()
        #expect(body.suggestions.map(\.title) == ["Standup"])
        let again = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(review.occurrenceId)"}
            """)
        #expect(again.status == 409)
        #expect(errorCode(again) == "event_unavailable")
        #expect(fixture.recording.recordingService.startCalls.count == 1)
    }

    // MARK: - Refusals

    @Test
    func anOccurrenceNoLongerSuggestedIsRefusedAndNothingStarts() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)
        fixture.clock.now = now.addingTimeInterval(6 * 60)

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)"}
            """)

        #expect(response.status == 409)
        #expect(errorCode(response) == "event_unavailable")
        #expect(fixture.recording.recordingService.startCalls.isEmpty)
        #expect(try fixture.recording.persistedSessions().isEmpty)
        #expect(fixture.recording.requestedSessions.isEmpty)
    }

    @Test
    func aMovedOccurrenceIsRefused() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)
        fixture.setEvents([.fixture(start: now.addingTimeInterval(60))])

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)"}
            """)

        #expect(response.status == 409)
        #expect(errorCode(response) == "event_unavailable")
        #expect(fixture.recording.recordingService.startCalls.isEmpty)
    }

    @Test
    func anUnknownOccurrenceIsRefused() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: #"{"occurrenceId": "nope"}"#)

        #expect(response.status == 409)
        #expect(errorCode(response) == "event_unavailable")
        #expect(fixture.recording.recordingService.startCalls.isEmpty)
    }

    @Test
    func aStartIsRefusedWhenSuggestionsAreOff() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)
        await fixture.controller.setEnabled(false)

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)"}
            """)

        #expect(response.status == 409)
        #expect(errorCode(response) == "event_unavailable")
        #expect(fixture.recording.recordingService.startCalls.isEmpty)
    }

    @Test(arguments: [
        "",
        "{}",
        #"{"occurrenceId": ""}"#,
        #"{"occurrenceId": 5}"#,
        #"{"occurrenceId": "x", "microphoneUid": "missing-mic"}"#,
    ])
    func anInvalidBodyIsRefusedBeforeCapture(json: String) async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: json)

        #expect(response.status == 400)
        #expect(errorCode(response) == "invalid_request")
        #expect(fixture.recording.recordingService.startCalls.isEmpty)
    }

    @Test
    func anUnknownTagIsRefusedBeforeCapture() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)", "tagIds": ["\(UUID().uuidString)"]}
            """)

        #expect(response.status == 400)
        #expect(errorCode(response) == "unknown_tag")
        #expect(fixture.recording.recordingService.startCalls.isEmpty)
        #expect(try await fixture.suggestions().suggestions.count == 1)
    }

    @Test
    func aStartWhileRecordingIsRefusedAndTheOccurrenceStaysSuggested() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)
        _ = await fixture.send("POST", "/v1/recordings/quick-start")

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)"}
            """)

        #expect(response.status == 409)
        #expect(errorCode(response) == "already_recording")
        #expect(fixture.recording.recordingService.startCalls.count == 1)
        _ = await fixture.send("POST", "/v1/recordings/stop")
        #expect(try await fixture.suggestions().suggestions.map(\.occurrenceId) == [occurrence.occurrenceId])
    }

    @Test
    func aStartRefusedForMissingModelsLeavesTheOccurrenceSuggested() async throws {
        let fixture = try Fixture(now: now)
        try await fixture.recording.pair()
        fixture.setEvents([.fixture(start: now)])
        await fixture.enableSuggestions()
        let occurrence = try #require(try await fixture.suggestions().suggestions.first)
        fixture.recording.modelsReady = false

        let response = await fixture.send("POST", "/v1/recordings/from-calendar", json: """
            {"occurrenceId": "\(occurrence.occurrenceId)"}
            """)

        #expect(response.status == 409)
        #expect(errorCode(response) == "models_missing")
        #expect(try await fixture.suggestions().suggestions.map(\.occurrenceId) == [occurrence.occurrenceId])
    }
}
