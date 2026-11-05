import Foundation
import Network
import Observation
import OSLog

/// Keeps the listener in step with `ExtensionAPISettings`: listening while enabled, on the
/// configured port, and stopped otherwise. A bind failure leaves the API stopped and readable in
/// `state` for Settings.
@MainActor
@Observable
final class ExtensionAPIService {
    struct BindFailure: Equatable, Sendable {
        let port: Int
        /// What Network reported, or nil when the failure had no network error.
        let error: NWError?
    }

    enum State: Equatable, Sendable {
        case stopped
        case listening(port: Int)
        case failed(BindFailure)
    }

    private(set) var state = State.stopped

    @ObservationIgnored private let settings: ExtensionAPISettings
    @ObservationIgnored private let handler: any ExtensionAPIRequestHandling
    @ObservationIgnored private let limits: ExtensionAPIListener.Limits
    @ObservationIgnored private var listener: ExtensionAPIListener?
    /// The port of the current listener and of the last attempt, so an unchanged failed port is
    /// not retried on every unrelated settings read.
    @ObservationIgnored private var appliedConfiguration: (enabled: Bool, port: Int)?
    /// Applies run one after another so a quick off-on cannot interleave two binds.
    @ObservationIgnored private var lastApply: Task<Void, Never>?
    @ObservationIgnored private var isFollowingSettings = false
    @ObservationIgnored private let logger = Logger(subsystem: "Scriberman", category: "ExtensionAPIService")

    init(
        settings: ExtensionAPISettings,
        handler: any ExtensionAPIRequestHandling,
        limits: ExtensionAPIListener.Limits = .init()
    ) {
        self.settings = settings
        self.handler = handler
        self.limits = limits
    }

    /// Applies the settings now and again after every change to them. Called once at launch.
    func start() {
        guard !isFollowingSettings else { return }
        isFollowingSettings = true
        followSettings()
    }

    /// Brings the listener in line with the settings and returns once it is.
    func apply() async {
        let previous = lastApply
        let task = Task { @MainActor in
            await previous?.value
            await reconcile()
        }
        lastApply = task
        await task.value
    }

    /// Stops listening at once and stops following the settings. For quit and tests.
    func stopNow() {
        isFollowingSettings = false
        let handler = handler
        Task { await handler.apiDidStop() }
        listener?.stop()
        listener = nil
        appliedConfiguration = nil
        state = .stopped
    }

    private func followSettings() {
        guard isFollowingSettings else { return }
        withObservationTracking {
            _ = settings.isEnabled
            _ = settings.port
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.followSettings()
                await self.apply()
            }
        }
        Task { await apply() }
    }

    private func reconcile() async {
        let wanted = (enabled: settings.isEnabled, port: settings.port)
        if let applied = appliedConfiguration, applied == wanted {
            return
        }
        appliedConfiguration = wanted

        if listener != nil {
            await handler.apiDidStop()
        }
        listener?.stop()
        listener = nil
        state = .stopped
        guard wanted.enabled else { return }

        let listener = ExtensionAPIListener(handler: handler, limits: limits)
        do {
            _ = try await listener.start(port: UInt16(wanted.port))
            // The settings may have moved on while binding; the next apply handles that.
            self.listener = listener
            state = .listening(port: wanted.port)
        } catch {
            listener.stop()
            var networkError: NWError?
            if case .failed(let reported) = error as? ExtensionAPIListener.StartError {
                networkError = reported
            }
            logger.error("Extension API could not listen on port \(wanted.port, privacy: .public): \(String(describing: error), privacy: .public)")
            state = .failed(BindFailure(port: wanted.port, error: networkError))
        }
    }
}
