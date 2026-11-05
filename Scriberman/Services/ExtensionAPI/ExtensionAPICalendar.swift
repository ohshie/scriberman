import Foundation

/// The calendar routes: the suggestions the calendar suggestion controller would show now, and
/// starting a recording from one through the recording routes' start.
@MainActor
final class ExtensionAPICalendar {
    private let controller: CalendarSuggestionController
    private let recording: ExtensionAPIRecording

    init(controller: CalendarSuggestionController, recording: ExtensionAPIRecording) {
        self.controller = controller
        self.recording = recording
    }

    /// Suggestions run only while the feature is on and the app is ready for recording.
    private var isRunning: Bool {
        controller.preferences.isEnabled && controller.hasRuntimeWork
    }

    func suggestions() async -> HTTPResponse {
        if isRunning {
            await controller.refresh()
        }
        guard isRunning else {
            return ExtensionAPIHandler.json(SuggestionsBody(suggestions: [], suggestionsEnabled: false))
        }
        return ExtensionAPIHandler.json(SuggestionsBody(
            suggestions: controller.visibleSuggestions.map(SuggestionBody.init),
            suggestionsEnabled: true
        ))
    }

    /// Checks the body, then re-checks the occurrence against a fresh query as a start from the
    /// suggestion panel does, and marks it handled once capture has started.
    func start(body: Data) async -> HTTPResponse {
        guard let request = try? JSONDecoder().decode(StartRequest.self, from: body),
              !request.occurrenceId.isEmpty else {
            return ExtensionAPIHandler.error(.invalidRequest, status: 400)
        }
        var choice: CaptureChoice
        switch recording.makeChoice(from: body) {
        case .success(let made):
            choice = made
        case .failure(let refusal):
            return refusal.response
        }
        guard recording.isIdle else {
            return ExtensionAPIHandler.error(.alreadyRecording, status: 409)
        }
        guard let suggestion = await controller.validatedSuggestion(where: {
            Self.occurrenceID($0) == request.occurrenceId
        }) else {
            return ExtensionAPIHandler.error(.eventUnavailable, status: 409)
        }
        choice.title = AppState.sessionTitle(for: suggestion)
        return await recording.start(choice) { [controller] in
            controller.markStarted(suggestion)
        }
    }

    /// The opaque id a client sends back: the occurrence's digest, so calendar identifiers are not
    /// handed out.
    nonisolated private static func occurrenceID(_ suggestion: CalendarMeetingSuggestion) -> String {
        suggestion.occurrenceID.persistentKey
    }

    // MARK: - Bodies

    private struct StartRequest: Decodable {
        let occurrenceId: String
    }

    private struct SuggestionBody: Encodable {
        let occurrenceId: String
        let title: String
        let start: String
        let end: String

        init(_ suggestion: CalendarMeetingSuggestion) {
            let formatter = ISO8601DateFormatter()
            occurrenceId = ExtensionAPICalendar.occurrenceID(suggestion)
            title = suggestion.title
            start = formatter.string(from: suggestion.start)
            end = formatter.string(from: suggestion.end)
        }
    }

    private struct SuggestionsBody: Encodable {
        let suggestions: [SuggestionBody]
        let suggestionsEnabled: Bool
    }
}
