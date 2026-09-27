import AppKit
import Foundation
import Testing
@testable import Scriberman

@MainActor
final class CalendarSuggestionControllerTests {
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let clock: Clock
    private let defaults: UserDefaults
    private let workspaceCenter = NotificationCenter()
    private let center = NotificationCenter()
    private let work = CalendarSnapshot(id: "work", title: "Work", sourceTitle: "iCloud")
    private let home = CalendarSnapshot(id: "home", title: "Home", sourceTitle: "iCloud")

    init() {
        clock = Clock(start)
        defaults = UserDefaults(suiteName: "CalendarSuggestionControllerTests-\(UUID().uuidString)")!
    }

    private func makeController(service: MockCalendarService) -> CalendarSuggestionController {
        let clock = clock
        return CalendarSuggestionController(
            service: service,
            preferences: CalendarSuggestionPreferences(userDefaults: defaults),
            now: { clock.now },
            // Polling and boundary timers never fire on their own; tests drive time explicitly.
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            workspaceNotificationCenter: workspaceCenter,
            notificationCenter: center
        )
    }

    private func makeAuthorizedService(events: [CalendarEventSnapshot] = []) -> MockCalendarService {
        let service = MockCalendarService(status: .fullAccess)
        service.update {
            $0.calendars = [work, home]
            $0.events = events
        }
        return service
    }

    /// An enabled, activated controller whose first refresh has finished.
    private func makeRunningController(service: MockCalendarService) async -> CalendarSuggestionController {
        let controller = makeController(service: service)
        controller.activate()
        await controller.setEnabled(true)
        await controller.refresh()
        return controller
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    // MARK: - Opt-in and permission

    @Test("A disabled feature never queries events")
    func disabledNeverQueries() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = makeController(service: service)
        controller.activate()
        await controller.refresh()
        await controller.handleWake()
        controller.setCaptureActive(true)
        controller.setCaptureActive(false)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(service.eventQueryCount == 0)
        #expect(controller.suggestions.isEmpty)
        #expect(!controller.hasRuntimeWork)
    }

    @Test("Opting in requests access and enables on grant")
    func grantEnables() async {
        let service = MockCalendarService(status: .notDetermined)
        let controller = makeController(service: service)
        controller.activate()
        await controller.setEnabled(true)

        #expect(service.read(\.accessRequestCount) == 1)
        #expect(controller.preferences.isEnabled)
        #expect(controller.authorizationStatus == .fullAccess)
        #expect(controller.hasRuntimeWork)
    }

    @Test("Denying the request leaves the feature off")
    func denialLeavesOff() async {
        let service = MockCalendarService(status: .notDetermined)
        service.update { $0.statusAfterRequest = .denied }
        let controller = makeController(service: service)
        controller.activate()
        await controller.setEnabled(true)

        #expect(!controller.preferences.isEnabled)
        #expect(controller.authorizationStatus == .denied)
        #expect(!controller.hasRuntimeWork)
    }

    @Test("Denied or restricted access is not requested again and stays off", arguments: [
        CalendarAuthorizationStatus.denied, .restricted,
    ])
    func deniedStatusStaysOff(status: CalendarAuthorizationStatus) async {
        let service = MockCalendarService(status: status)
        let controller = makeController(service: service)
        controller.activate()
        await controller.setEnabled(true)

        #expect(service.read(\.accessRequestCount) == 0)
        #expect(!controller.preferences.isEnabled)
    }

    @Test("A late grant cannot re-enable a feature disabled during the request")
    func lateGrantAfterDisable() async {
        let service = MockCalendarService(status: .notDetermined)
        let gate = TestGate()
        service.update { $0.accessGate = gate }
        let controller = makeController(service: service)
        controller.activate()

        let request = Task { await controller.setEnabled(true) }
        #expect(await eventually { service.read(\.accessRequestCount) == 1 })
        #expect(controller.isRequestingAccess)

        await controller.setEnabled(false)
        gate.open()
        await request.value

        #expect(!controller.preferences.isEnabled)
        #expect(!controller.isRequestingAccess)
        #expect(!controller.hasRuntimeWork)
        #expect(service.eventQueryCount == 0)
    }

    @Test("Revoked access turns the feature off and removes suggestions")
    func revocation() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        #expect(controller.suggestions.count == 1)

        service.update { $0.status = .denied }
        await controller.refresh()

        #expect(!controller.preferences.isEnabled)
        #expect(controller.suggestions.isEmpty)
        #expect(!controller.hasRuntimeWork)
    }

    @Test("Access lost between launches turns the feature off at activation")
    func revokedAtLaunch() {
        CalendarSuggestionPreferences(userDefaults: defaults).isEnabled = true
        let service = MockCalendarService(status: .denied)
        let controller = makeController(service: service)
        controller.activate()

        #expect(!controller.preferences.isEnabled)
        #expect(service.eventQueryCount == 0)
    }

    @Test("Restored access alone does not re-enable the feature")
    func restorationDoesNotEnable() async {
        let service = MockCalendarService(status: .denied)
        let controller = makeController(service: service)
        controller.activate()
        await controller.setEnabled(true)

        service.update { $0.status = .fullAccess }
        await controller.refresh()

        #expect(!controller.preferences.isEnabled)
        #expect(service.eventQueryCount == 0)
    }

    @Test("Nothing runs before the app is ready")
    func waitsForReadiness() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = makeController(service: service)
        await controller.setEnabled(true)
        await controller.refresh()

        #expect(controller.preferences.isEnabled)
        #expect(service.eventQueryCount == 0)
        #expect(!controller.hasRuntimeWork)
    }

    // MARK: - Selection

    @Test("First enumeration selects every calendar; later calendars stay unselected")
    func seedsSelection() async {
        let service = makeAuthorizedService()
        let controller = await makeRunningController(service: service)
        #expect(controller.preferences.selectedCalendarIDs == ["work", "home"])

        service.update { $0.calendars.append(CalendarSnapshot(id: "new", title: "New", sourceTitle: "Google")) }
        await controller.refresh()
        #expect(controller.preferences.selectedCalendarIDs == ["work", "home"])
        #expect(controller.calendars.map(\.id).contains("new"))
    }

    @Test("An empty selection queries nothing and suggests nothing")
    func emptySelection() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        let queries = service.eventQueryCount

        controller.setCalendar("work", selected: false)
        controller.setCalendar("home", selected: false)
        #expect(controller.suggestions.isEmpty)
        await controller.refresh()

        #expect(controller.suggestions.isEmpty)
        #expect(service.eventQueryCount == queries)
    }

    @Test("A removed calendar stops producing suggestions without selecting a replacement")
    func removedCalendar() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        controller.setCalendar("home", selected: false)
        await controller.refresh()

        service.update { $0.calendars = [self.home] }
        await controller.refresh()

        #expect(controller.suggestions.isEmpty)
        #expect(controller.preferences.selectedCalendarIDs == ["work"])
    }

    @Test("Selection survives disabling and re-enabling")
    func selectionPreserved() async {
        let service = makeAuthorizedService()
        let controller = await makeRunningController(service: service)
        controller.setCalendar("home", selected: false)

        await controller.setEnabled(false)
        await controller.setEnabled(true)
        await controller.refresh()

        #expect(controller.preferences.selectedCalendarIDs == ["work"])
    }

    // MARK: - Refresh

    @Test("Store changes, wake and clock changes each trigger a refresh")
    func refreshTriggers() async {
        let service = makeAuthorizedService()
        let controller = await makeRunningController(service: service)
        var expected = service.eventQueryCount

        service.simulateStoreChange()
        expected += 1
        #expect(await eventually { service.eventQueryCount >= expected })

        expected = service.eventQueryCount + 1
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(await eventually { service.eventQueryCount >= expected })

        expected = service.eventQueryCount + 1
        center.post(name: .NSSystemClockDidChange, object: nil)
        #expect(await eventually { service.eventQueryCount >= expected })

        expected = service.eventQueryCount + 1
        center.post(name: .NSSystemTimeZoneDidChange, object: nil)
        #expect(await eventually { service.eventQueryCount >= expected })
        _ = controller
    }

    @Test("The fallback poll refreshes on its interval")
    func fallbackPolling() async {
        let service = makeAuthorizedService()
        let clock = clock
        let controller = CalendarSuggestionController(
            service: service,
            preferences: CalendarSuggestionPreferences(userDefaults: defaults),
            now: { clock.now },
            sleep: { try await Task.sleep(for: $0) },
            fallbackInterval: .milliseconds(10),
            workspaceNotificationCenter: workspaceCenter,
            notificationCenter: center
        )
        controller.activate()
        await controller.setEnabled(true)

        #expect(await eventually { service.eventQueryCount >= 3 })
        await controller.setEnabled(false)
    }

    @Test("Results from an obsolete selection are discarded")
    func staleResultsDiscarded() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        let gate = TestGate()
        service.update { $0.eventsGate = gate }
        let queries = service.eventQueryCount

        let inFlight = Task { await controller.refresh() }
        #expect(await eventually { service.eventQueryCount == queries + 1 })
        controller.setCalendar("work", selected: false)
        service.update { $0.eventsGate = nil }
        gate.open()
        await inFlight.value
        await controller.refresh()

        #expect(controller.suggestions.isEmpty)
    }

    @Test("A fetch failure clears cards without disabling; a retry recovers")
    func fetchFailureAndRetry() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        #expect(controller.suggestions.count == 1)

        service.update { $0.eventsError = MockCalendarError() }
        await controller.refresh()
        #expect(controller.suggestions.isEmpty)
        #expect(controller.refreshFailed)
        #expect(controller.preferences.isEnabled)

        service.update { $0.eventsError = nil }
        await controller.refresh()
        #expect(controller.suggestions.count == 1)
        #expect(!controller.refreshFailed)
    }

    @Test("Disabling removes cards and all runtime work")
    func disableRemovesRuntime() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        #expect(controller.hasRuntimeWork)

        await controller.setEnabled(false)
        let queries = service.eventQueryCount
        service.simulateStoreChange()
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(controller.suggestions.isEmpty)
        #expect(!controller.hasRuntimeWork)
        #expect(service.eventQueryCount == queries)
    }

    @Test("Cancelled or moved events disappear on refresh; titles update")
    func tracksEventChanges() async {
        let service = makeAuthorizedService(events: [.fixture(itemID: "a", start: start), .fixture(itemID: "b", start: start)])
        let controller = await makeRunningController(service: service)
        #expect(controller.suggestions.count == 2)

        service.update {
            $0.events = [
                .fixture(itemID: "a", title: "Renamed", start: self.start),
                .fixture(itemID: "b", start: self.start.addingTimeInterval(3_600)),
            ]
        }
        service.simulateStoreChange()
        #expect(await eventually { controller.suggestions.map(\.title) == ["Renamed"] })
    }

    // MARK: - Suppression and capture

    @Test("A dismissed occurrence stays dismissed after relaunch")
    func dismissalSurvivesRelaunch() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        controller.dismiss(controller.suggestions[0].id)
        #expect(controller.suggestions.isEmpty)

        let relaunched = await makeRunningController(service: service)
        #expect(relaunched.suggestions.isEmpty)
    }

    @Test("A prepared occurrence stays handled after relaunch")
    func preparationSurvivesRelaunch() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        controller.markPrepared(controller.suggestions[0].id)

        let relaunched = await makeRunningController(service: service)
        #expect(relaunched.suggestions.isEmpty)
    }

    @Test("An untouched card returns after relaunch within its window")
    func untouchedReturns() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        _ = await makeRunningController(service: service)

        clock.now = start.addingTimeInterval(120)
        let relaunched = await makeRunningController(service: service)
        #expect(relaunched.suggestions.count == 1)
    }

    @Test("Capture hides suggestions without consuming them")
    func captureHides() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)

        controller.setCaptureActive(true)
        #expect(controller.visibleSuggestions.isEmpty)
        #expect(controller.suggestions.count == 1)

        controller.setCaptureActive(false)
        #expect(controller.visibleSuggestions.isEmpty)
        #expect(await eventually { controller.visibleSuggestions.count == 1 })
    }

    @Test("Capture ending after a window closed shows nothing")
    func captureEndAfterExpiry() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        controller.setCaptureActive(true)

        clock.now = start.addingTimeInterval(600)
        controller.setCaptureActive(false)
        #expect(controller.visibleSuggestions.isEmpty)
        await controller.refresh()
        #expect(controller.visibleSuggestions.isEmpty)
    }

    @Test("Wake after a window closed shows nothing and builds no backlog")
    func wakeAfterExpiry() async {
        let service = makeAuthorizedService(events: [
            .fixture(itemID: "missed", start: start),
            .fixture(itemID: "current", start: start.addingTimeInterval(3_600)),
        ])
        let controller = await makeRunningController(service: service)

        clock.now = start.addingTimeInterval(3_600)
        await controller.handleWake()
        #expect(controller.suggestions.map(\.occurrenceID.calendarItemID) == ["current"])
    }

    @Test("Re-evaluation at a later time removes expired suggestions")
    func expiry() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        clock.now = start.addingTimeInterval(300)
        controller.reevaluate()
        #expect(controller.suggestions.isEmpty)
    }

    @Test("Validation returns the fresh suggestion and drops a cancelled one")
    func validation() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        let id = controller.suggestions[0].id

        service.update { $0.events = [.fixture(title: "Updated", start: self.start)] }
        #expect(await controller.validatedSuggestion(id)?.title == "Updated")

        service.update { $0.events = [.fixture(start: self.start, status: .cancelled)] }
        #expect(await controller.validatedSuggestion(id) == nil)
        #expect(controller.suggestions.isEmpty)
    }

    @Test("Validation refuses while capture is active")
    func validationDuringCapture() async {
        let service = makeAuthorizedService(events: [.fixture(start: start)])
        let controller = await makeRunningController(service: service)
        let id = controller.suggestions[0].id
        controller.setCaptureActive(true)
        #expect(await controller.validatedSuggestion(id) == nil)
        #expect(controller.suggestions.count == 1)
    }
}
