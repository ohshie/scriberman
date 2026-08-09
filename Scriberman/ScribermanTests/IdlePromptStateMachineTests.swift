import Foundation
import Testing
@testable import Scriberman

struct IdlePromptStateMachineTests {
    private let start = Date(timeIntervalSince1970: 2_000_000)
    private let threshold: TimeInterval = 5 * 60

    private func settings(
        enabled: Bool = true,
        app: Bool = true,
        mic: Bool = false,
        input: Bool = false,
        allIdle: Bool = true,
        autoStop: Bool = false,
        autoStopDelay: TimeInterval = 5 * 60
    ) -> IdlePromptSettings {
        IdlePromptSettings(
            isEnabled: enabled,
            watchAppAudio: app,
            watchMicAudio: mic,
            watchUserInput: input,
            requiresAllSourcesIdle: allIdle,
            idleThreshold: threshold,
            autoStopEnabled: autoStop,
            autoStopDelay: autoStopDelay
        )
    }

    @discardableResult
    private func tick(
        _ machine: inout IdlePromptStateMachine,
        at offset: TimeInterval,
        snapshot: IdleActivitySnapshot,
        settings: IdlePromptSettings,
        applicable: Bool = true
    ) -> IdlePromptStateMachine.Effect {
        machine.update(
            now: start.addingTimeInterval(offset),
            snapshot: snapshot,
            settings: settings,
            recordingStartedAt: start,
            isApplicable: applicable
        )
    }

    // MARK: - Source combination

    @Test("All-idle rule is governed by the most recent activity")
    func allIdleUsesMostRecent() {
        let snapshot = IdleActivitySnapshot(
            appAudio: start,                              // silent since the start
            micAudio: start.addingTimeInterval(600),      // spoke 10 min in
            userInput: nil
        )
        let result = IdlePromptStateMachine.effectiveLastActivity(
            snapshot: snapshot,
            settings: settings(app: true, mic: true, allIdle: true),
            recordingStartedAt: start
        )
        #expect(result == start.addingTimeInterval(600))
    }

    @Test("Any-idle rule is governed by the oldest activity")
    func anyIdleUsesOldest() {
        let snapshot = IdleActivitySnapshot(
            appAudio: start,
            micAudio: start.addingTimeInterval(600),
            userInput: nil
        )
        let result = IdlePromptStateMachine.effectiveLastActivity(
            snapshot: snapshot,
            settings: settings(app: true, mic: true, allIdle: false),
            recordingStartedAt: start
        )
        #expect(result == start)
    }

    @Test("A watched source that was never active falls back to the recording start")
    func neverActiveFallsBackToStart() {
        let result = IdlePromptStateMachine.effectiveLastActivity(
            snapshot: IdleActivitySnapshot(),
            settings: settings(),
            recordingStartedAt: start
        )
        #expect(result == start)
    }

    @Test("No watched sources means the feature is inert")
    func noWatchedSources() {
        let result = IdlePromptStateMachine.effectiveLastActivity(
            snapshot: IdleActivitySnapshot(appAudio: start),
            settings: settings(app: false, mic: false, input: false),
            recordingStartedAt: start
        )
        #expect(result == nil)
    }

    // MARK: - Prompting

    @Test("Prompt appears once the idle threshold is crossed")
    func promptsAfterThreshold() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)

        #expect(tick(&machine, at: 60, snapshot: snapshot, settings: settings()) == .none)
        #expect(tick(&machine, at: 299, snapshot: snapshot, settings: settings()) == .none)
        #expect(tick(&machine, at: 300, snapshot: snapshot, settings: settings()) == .showPrompt)
    }

    @Test("Prompt is not repeated on subsequent ticks")
    func promptIsNotRepeated() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)
        #expect(tick(&machine, at: 300, snapshot: snapshot, settings: settings()) == .showPrompt)
        #expect(tick(&machine, at: 320, snapshot: snapshot, settings: settings()) == .none)
        #expect(tick(&machine, at: 900, snapshot: snapshot, settings: settings()) == .none)
    }

    @Test("Resumed activity dismisses the prompt")
    func activityDismissesPrompt() {
        var machine = IdlePromptStateMachine()
        #expect(tick(&machine, at: 300, snapshot: IdleActivitySnapshot(appAudio: start), settings: settings()) == .showPrompt)

        // Meeting resumes at t+310.
        let resumed = IdleActivitySnapshot(appAudio: start.addingTimeInterval(310))
        #expect(tick(&machine, at: 311, snapshot: resumed, settings: settings()) == .dismissPrompt)
        #expect(machine.state == .monitoring)
    }

    @Test("Feature disabled never prompts and dismisses an open prompt")
    func disabledDismisses() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)
        #expect(tick(&machine, at: 300, snapshot: snapshot, settings: settings()) == .showPrompt)
        #expect(tick(&machine, at: 301, snapshot: snapshot, settings: settings(enabled: false)) == .dismissPrompt)
    }

    @Test("Non-applicable session never prompts")
    func notApplicableNeverPrompts() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)
        #expect(tick(&machine, at: 3_000, snapshot: snapshot, settings: settings(), applicable: false) == .none)
        #expect(machine.state == .monitoring)
    }

    // MARK: - Snooze

    @Test("Snooze suppresses prompting then re-prompts")
    func snoozeSuppressesThenRePrompts() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)
        #expect(tick(&machine, at: 300, snapshot: snapshot, settings: settings()) == .showPrompt)

        machine.snooze(for: 5 * 60, now: start.addingTimeInterval(300))

        #expect(tick(&machine, at: 400, snapshot: snapshot, settings: settings()) == .none)
        #expect(tick(&machine, at: 599, snapshot: snapshot, settings: settings()) == .none)
        #expect(tick(&machine, at: 600, snapshot: snapshot, settings: settings()) == .showPrompt)
    }

    @Test("Activity during a snooze returns to monitoring")
    func activityCancelsSnooze() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)
        _ = tick(&machine, at: 300, snapshot: snapshot, settings: settings())
        machine.snooze(for: 5 * 60, now: start.addingTimeInterval(300))

        let resumed = IdleActivitySnapshot(appAudio: start.addingTimeInterval(350))
        #expect(tick(&machine, at: 351, snapshot: resumed, settings: settings()) == .none)
        #expect(machine.state == .monitoring)
    }

    // MARK: - Auto stop

    @Test("Auto stop is off by default so an ignored prompt keeps recording")
    func autoStopDisabled() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)
        _ = tick(&machine, at: 300, snapshot: snapshot, settings: settings())
        #expect(tick(&machine, at: 100_000, snapshot: snapshot, settings: settings()) == .none)
    }

    @Test("Auto stop fires after the configured delay")
    func autoStopFiresAfterDelay() {
        var machine = IdlePromptStateMachine()
        let snapshot = IdleActivitySnapshot(appAudio: start)
        let config = settings(autoStop: true, autoStopDelay: 5 * 60)

        #expect(tick(&machine, at: 300, snapshot: snapshot, settings: config) == .showPrompt)
        #expect(tick(&machine, at: 500, snapshot: snapshot, settings: config) == .none)
        #expect(tick(&machine, at: 600, snapshot: snapshot, settings: config) == .autoStop)
    }

    @Test("Auto stop does not fire if activity resumes first")
    func autoStopCancelledByActivity() {
        var machine = IdlePromptStateMachine()
        let config = settings(autoStop: true, autoStopDelay: 5 * 60)
        _ = tick(&machine, at: 300, snapshot: IdleActivitySnapshot(appAudio: start), settings: config)

        let resumed = IdleActivitySnapshot(appAudio: start.addingTimeInterval(400))
        #expect(tick(&machine, at: 401, snapshot: resumed, settings: config) == .dismissPrompt)
        // t+620 is past the original prompt's auto-stop deadline (300 + 300), but the machine
        // reset when activity resumed, and the new idle run (220 s) is still under threshold.
        #expect(tick(&machine, at: 620, snapshot: resumed, settings: config) == .none)
    }

    @Test("A fresh idle run after activity prompts again")
    func rePromptsAfterNewIdleRun() {
        var machine = IdlePromptStateMachine()
        let config = settings()
        _ = tick(&machine, at: 300, snapshot: IdleActivitySnapshot(appAudio: start), settings: config)

        let resumed = IdleActivitySnapshot(appAudio: start.addingTimeInterval(400))
        #expect(tick(&machine, at: 401, snapshot: resumed, settings: config) == .dismissPrompt)
        // Idle again for a full threshold from the new activity.
        #expect(tick(&machine, at: 700, snapshot: resumed, settings: config) == .showPrompt)
    }

    @Test("User input keeps a presenting session alive under the all-idle rule")
    func userInputVetoesPresentation() {
        var machine = IdlePromptStateMachine()
        let config = settings(app: true, input: true, allIdle: true)
        // App audio silent since the start (everyone else muted), but the user keeps clicking.
        let snapshot = IdleActivitySnapshot(
            appAudio: start,
            userInput: start.addingTimeInterval(590)
        )
        #expect(tick(&machine, at: 600, snapshot: snapshot, settings: config) == .none)
    }
}
