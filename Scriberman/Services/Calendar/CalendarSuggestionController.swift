import AppKit
import Foundation
import Observation

/// Owns calendar opt-in, permission handling, refresh scheduling and the current suggestions.
///
/// Every asynchronous result is checked against a generation counter before it changes state, so
/// a late permission grant or query cannot undo a newer disable or selection change.
@MainActor
@Observable
final class CalendarSuggestionController {
    enum CalendarListState: Equatable {
        case notLoaded
        case loaded
        case failed
    }

    let preferences: CalendarSuggestionPreferences
    private(set) var authorizationStatus: CalendarAuthorizationStatus
    private(set) var isRequestingAccess = false
    private(set) var calendars: [CalendarSnapshot] = []
    private(set) var calendarListState: CalendarListState = .notLoaded
    /// True after the last event query failed. Cleared by the next successful refresh.
    private(set) var refreshFailed = false
    /// Current in-window suggestions, before capture gating.
    private(set) var suggestions: [CalendarMeetingSuggestion] = []
    private(set) var isCaptureActive = false

    @ObservationIgnored private let service: CalendarServiceProtocol
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let fallbackInterval: Duration
    @ObservationIgnored private let workspaceNotificationCenter: NotificationCenter
    @ObservationIgnored private let notificationCenter: NotificationCenter

    @ObservationIgnored private var isAppReady = false
    @ObservationIgnored private var events: [CalendarEventSnapshot] = []
    @ObservationIgnored private var accessRequestGeneration = 0
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var runtimeTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var boundaryTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false

    init(
        service: CalendarServiceProtocol,
        preferences: CalendarSuggestionPreferences,
        now: @escaping @MainActor () -> Date = { .now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        fallbackInterval: Duration = .seconds(60),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        notificationCenter: NotificationCenter = .default
    ) {
        self.service = service
        self.preferences = preferences
        self.now = now
        self.sleep = sleep
        self.fallbackInterval = fallbackInterval
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.notificationCenter = notificationCenter
        self.authorizationStatus = service.authorizationStatus()
    }

    /// Suggestions to present: none while recording or dictation is active.
    var visibleSuggestions: [CalendarMeetingSuggestion] {
        isCaptureActive ? [] : suggestions
    }

    /// True while observers, timers or polling are scheduled.
    var hasRuntimeWork: Bool {
        !runtimeTasks.isEmpty || boundaryTask != nil
    }

    // MARK: - Lifecycle

    /// Called once the app is ready for recording. Suggestions never run before this.
    func activate() {
        guard !isAppReady else { return }
        isAppReady = true
        preferences.pruneHandled(now: now())
        authorizationStatus = service.authorizationStatus()
        guard preferences.isEnabled else { return }
        if authorizationStatus == .fullAccess {
            startRuntime()
        } else {
            turnOffForMissingAccess()
        }
    }

    func shutdown() {
        isAppReady = false
        stopRuntime()
    }

    // MARK: - Enablement

    /// The single enablement path for the invitation and Settings. Enabling requests access when
    /// it was never asked for and turns the feature on only after access is granted.
    func setEnabled(_ enabled: Bool) async {
        accessRequestGeneration += 1
        let generation = accessRequestGeneration

        guard enabled else {
            isRequestingAccess = false
            preferences.isEnabled = false
            stopRuntime()
            return
        }

        authorizationStatus = service.authorizationStatus()
        switch authorizationStatus {
        case .fullAccess:
            turnOn()
        case .denied, .restricted:
            preferences.isEnabled = false
        case .notDetermined:
            isRequestingAccess = true
            let granted = (try? await service.requestAccess()) ?? false
            // A disable, or a newer enable, happened while the request was outstanding.
            guard generation == accessRequestGeneration else { return }
            isRequestingAccess = false
            authorizationStatus = service.authorizationStatus()
            if granted && authorizationStatus == .fullAccess {
                turnOn()
            } else {
                preferences.isEnabled = false
            }
        }
    }

    private func turnOn() {
        preferences.isEnabled = true
        if isAppReady {
            startRuntime()
        }
    }

    private func turnOffForMissingAccess() {
        preferences.isEnabled = false
        stopRuntime()
    }

    // MARK: - Calendar selection

    func setCalendar(_ calendarID: String, selected: Bool) {
        preferences.setCalendar(calendarID, selected: selected)
        queryGeneration += 1
        reevaluate()
        Task { await refresh() }
    }

    /// Enumerates calendars for Settings without querying events. Seeds the selection on the
    /// first successful enumeration.
    func loadCalendars() async {
        authorizationStatus = service.authorizationStatus()
        guard authorizationStatus == .fullAccess else { return }
        do {
            applyCalendars(try await service.calendars())
        } catch {
            calendarListState = .failed
        }
    }

    private func applyCalendars(_ loaded: [CalendarSnapshot]) {
        calendars = loaded.sorted {
            ($0.sourceTitle, $0.title, $0.id) < ($1.sourceTitle, $1.title, $1.id)
        }
        calendarListState = .loaded
        preferences.seedSelectionIfNeeded(availableCalendarIDs: Set(loaded.map(\.id)))
    }

    // MARK: - Refresh

    /// Fetches the current range and recomputes suggestions. Concurrent calls coalesce: a call
    /// made while a refresh runs causes one more pass after it, and returns when that pass ends.
    func refresh() async {
        needsRefresh = true
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            while let self, self.needsRefresh {
                self.needsRefresh = false
                await self.performRefresh()
            }
            self?.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func performRefresh() async {
        guard preferences.isEnabled, isAppReady else { return }
        let generation = queryGeneration

        authorizationStatus = service.authorizationStatus()
        guard authorizationStatus == .fullAccess else {
            turnOffForMissingAccess()
            return
        }

        do {
            let loaded = try await service.calendars()
            guard generation == queryGeneration else { return }
            applyCalendars(loaded)

            let available = Set(loaded.map(\.id))
            let selected = preferences.selectedCalendarIDs.intersection(available)
            let range = CalendarSuggestionPolicy.queryRange(now: now())
            let fetched = selected.isEmpty
                ? []
                : try await service.events(calendarIDs: selected, from: range.start, to: range.end)
            guard generation == queryGeneration else { return }

            preferences.pruneHandled(now: now())
            events = fetched
            refreshFailed = false
            reevaluate()
        } catch {
            guard generation == queryGeneration else { return }
            events = []
            suggestions = []
            refreshFailed = true
            boundaryTask?.cancel()
            boundaryTask = nil
        }
    }

    /// Recomputes suggestions from the last fetched events at the current time, and schedules
    /// the next window boundary.
    func reevaluate() {
        let current = now()
        let selected = preferences.selectedCalendarIDs
        suggestions = CalendarSuggestionPolicy.suggestions(
            from: events,
            selectedCalendarIDs: selected,
            now: current,
            isHandled: preferences.isHandled
        )
        boundaryTask?.cancel()
        boundaryTask = nil
        guard !runtimeTasks.isEmpty,
              let next = CalendarSuggestionPolicy.nextBoundary(after: current, events: events, selectedCalendarIDs: selected)
        else { return }
        let delay = Duration.milliseconds(Int64((next.timeIntervalSince(current) * 1000).rounded(.up)))
        boundaryTask = Task { @MainActor [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            self?.reevaluate()
        }
    }

    /// Wake replays nothing: stale cards go first, then a fresh query decides what shows.
    func handleWake() async {
        suggestions = []
        await refresh()
    }

    /// Recording and dictation hide suggestions without consuming them. When capture ends the
    /// cards stay hidden until a fresh query, so an expired meeting is never shown.
    func setCaptureActive(_ active: Bool) {
        guard active != isCaptureActive else { return }
        isCaptureActive = active
        if !active {
            suggestions = []
            Task { await refresh() }
        }
    }

    private func startRuntime() {
        guard runtimeTasks.isEmpty else { return }
        queryGeneration += 1

        let changes = service.storeChanges()
        runtimeTasks.append(Task { @MainActor [weak self] in
            for await _ in changes {
                await self?.refresh()
            }
        })
        runtimeTasks.append(Task { @MainActor [weak self, sleep, fallbackInterval] in
            while !Task.isCancelled {
                do { try await sleep(fallbackInterval) } catch { return }
                await self?.refresh()
            }
        })
        runtimeTasks.append(observe(NSWorkspace.didWakeNotification, on: workspaceNotificationCenter) {
            await $0.handleWake()
        })
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            runtimeTasks.append(observe(name, on: notificationCenter) { await $0.refresh() })
        }

        Task { await refresh() }
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        action: @escaping @MainActor (CalendarSuggestionController) async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            for await _ in center.notifications(named: name).map({ _ in () }) {
                guard let self else { return }
                await action(self)
            }
        }
    }

    private func stopRuntime() {
        runtimeTasks.forEach { $0.cancel() }
        runtimeTasks.removeAll()
        boundaryTask?.cancel()
        boundaryTask = nil
        queryGeneration += 1
        events = []
        suggestions = []
        refreshFailed = false
    }

    // MARK: - Actions

    /// Re-queries and returns the suggestion only if it is still current and capture is idle.
    /// A suggestion that is no longer eligible has been removed by the refresh.
    func validatedSuggestion(_ id: CalendarOccurrenceID) async -> CalendarMeetingSuggestion? {
        await refresh()
        guard !isCaptureActive, preferences.isEnabled else { return nil }
        return suggestions.first { $0.id == id }
    }

    func dismiss(_ id: CalendarOccurrenceID) {
        markHandled(id)
    }

    func markPrepared(_ id: CalendarOccurrenceID) {
        markHandled(id)
    }

    private func markHandled(_ id: CalendarOccurrenceID) {
        guard let suggestion = suggestions.first(where: { $0.id == id }) else { return }
        preferences.markHandled(id, expiresAt: suggestion.windowEnd)
        suggestions.removeAll { $0.id == id }
    }
}
