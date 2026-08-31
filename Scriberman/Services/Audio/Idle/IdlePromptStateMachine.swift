import Foundation

/// Drives the idle session prompt: decides when the session counts as idle, when to show
/// the prompt, when snoozing expires, and when (optionally) to stop automatically.
///
/// Pure and time-injected — every decision is a function of `now` plus the activity
/// snapshot, so the whole state machine is unit-testable without waiting on real clocks.
struct IdlePromptStateMachine: Equatable {
    enum State: Equatable {
        /// Watching; either active or counting toward the threshold (behaviourally identical).
        case monitoring
        /// Prompt is on screen, waiting for the user. Recording continues.
        case prompting(since: Date)
        /// User snoozed; no prompting until this moment passes.
        case snoozed(until: Date)
    }

    /// What the caller should do as a result of this evaluation.
    enum Effect: Equatable {
        case none
        case showPrompt
        case dismissPrompt
        case autoStop
    }

    private(set) var state: State = .monitoring

    /// Combines the watched sources into a single "last activity" instant.
    ///
    /// - "all must be idle" → the **most recent** watched activity governs, so any active
    ///   source keeps the session alive.
    /// - "any idle triggers" → the **oldest** watched activity governs, so a single quiet
    ///   source is enough.
    ///
    /// A watched source that has never been active falls back to `recordingStartedAt`, so
    /// idleness is measured from the beginning of the recording rather than never at all.
    /// Returns nil when nothing is watched (feature inert).
    static func effectiveLastActivity(
        snapshot: IdleActivitySnapshot,
        settings: IdlePromptSettings,
        recordingStartedAt: Date
    ) -> Date? {
        var values: [Date] = []
        if settings.watchAppAudio { values.append(snapshot.appAudio ?? recordingStartedAt) }
        if settings.watchMicAudio { values.append(snapshot.micAudio ?? recordingStartedAt) }
        if settings.watchUserInput { values.append(snapshot.userInput ?? recordingStartedAt) }
        guard !values.isEmpty else { return nil }
        return settings.requiresAllSourcesIdle ? values.max() : values.min()
    }

    /// Advance the machine. `isApplicable` gates the whole feature (e.g. the session must
    /// capture both microphone and app audio).
    mutating func update(
        now: Date,
        snapshot: IdleActivitySnapshot,
        settings: IdlePromptSettings,
        recordingStartedAt: Date,
        isApplicable: Bool
    ) -> Effect {
        guard isApplicable, settings.isEnabled,
              let lastActivity = Self.effectiveLastActivity(
                  snapshot: snapshot,
                  settings: settings,
                  recordingStartedAt: recordingStartedAt
              )
        else {
            return reset()
        }

        let idle = now.timeIntervalSince(lastActivity)
        guard idle >= settings.idleThreshold else {
            // Activity resumed (or never stopped): the question answers itself.
            return reset()
        }

        switch state {
        case .monitoring:
            state = .prompting(since: now)
            return .showPrompt

        case .prompting(let since):
            guard settings.autoStopEnabled,
                  now.timeIntervalSince(since) >= settings.autoStopDelay else {
                return .none
            }
            state = .monitoring
            return .autoStop

        case .snoozed(let until):
            guard now >= until else { return .none }
            state = .prompting(since: now)
            return .showPrompt
        }
    }

    /// User chose a snooze duration: dismiss and suppress prompting for that long.
    mutating func snooze(for duration: TimeInterval, now: Date) {
        state = .snoozed(until: now.addingTimeInterval(duration))
    }

    /// Returns to monitoring, dismissing the prompt if one was showing.
    private mutating func reset() -> Effect {
        if case .prompting = state {
            state = .monitoring
            return .dismissPrompt
        }
        state = .monitoring
        return .none
    }
}
