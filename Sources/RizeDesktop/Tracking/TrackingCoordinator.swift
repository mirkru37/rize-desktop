import Foundation

/// Wires the OS-backed signal sources to a `TrackingEngine` instance: two
/// long-lived listener loops for the event-driven signals (frontmost-app
/// activation, lock/sleep/wake), and a polling loop for window title, idle
/// time, and the Accessibility permission check, per
/// `documentation/architecture-desktop.md` §Tracking Pipeline.
///
/// This type is intentionally thin glue over `TrackingEngine` and holds no
/// tracking logic of its own — everything decision-worthy lives in the
/// engine so it can be unit-tested. The coordinator itself depends only on
/// the signal-source protocols, not on AppKit/Accessibility/CoreGraphics
/// directly; `AppDelegate` supplies the real, OS-backed implementations.
final class TrackingCoordinator {
    private let engine: TrackingEngine
    private let frontmostAppSource: FrontmostAppSignalSource
    private let windowTitleSource: WindowTitleSignalSource
    private let idleTimeSource: IdleTimeSignalSource
    private let systemStateSource: SystemStateSignalSource
    private let permissionSource: AccessibilityPermissionSource
    private let pollingInterval: Duration

    private var frontmostAppTask: Task<Void, Never>?
    private var systemStateTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    /// Which signal `signalAppliedProbe` just finished applying to the
    /// engine.
    enum AppliedSignal: Equatable {
        case frontmostApp
        case systemState
        case poll
    }

    /// Test-only: invoked immediately after each signal has been fully
    /// applied to the engine (i.e. the corresponding `engine.handle*` call
    /// has returned), so tests can deterministically sequence a clock
    /// advance or assertion against "this signal has taken effect" instead
    /// of guessing with a wall-clock delay or a fixed-interval polling loop.
    /// Nil in production.
    var signalAppliedProbe: (@Sendable (AppliedSignal) -> Void)?

    /// - Parameter pollingInterval: How often the window-title/idle-time/
    ///   permission loop runs. Defaults to 2s, within the doc's 1-5s range.
    init(
        engine: TrackingEngine,
        frontmostAppSource: FrontmostAppSignalSource,
        windowTitleSource: WindowTitleSignalSource,
        idleTimeSource: IdleTimeSignalSource,
        systemStateSource: SystemStateSignalSource,
        permissionSource: AccessibilityPermissionSource,
        pollingInterval: Duration = .seconds(2)
    ) {
        self.engine = engine
        self.frontmostAppSource = frontmostAppSource
        self.windowTitleSource = windowTitleSource
        self.idleTimeSource = idleTimeSource
        self.systemStateSource = systemStateSource
        self.permissionSource = permissionSource
        self.pollingInterval = pollingInterval
    }

    /// Starts (or restarts) all listener/polling loops.
    func start() {
        stop()
        frontmostAppTask = Task { [weak self, engine, frontmostAppSource] in
            for await sample in frontmostAppSource.events() {
                await engine.handleFrontmostAppChanged(bundleID: sample.bundleID)
                self?.signalAppliedProbe?(.frontmostApp)
            }
        }
        systemStateTask = Task { [weak self, engine, systemStateSource] in
            for await signal in systemStateSource.events() {
                await engine.handleSystemStateSignal(signal)
                self?.signalAppliedProbe?(.systemState)
            }
        }
        pollingTask = Task { [weak self] in
            await self?.runPollingLoop()
        }
    }

    /// Cancels all listener/polling loops.
    func stop() {
        frontmostAppTask?.cancel()
        systemStateTask?.cancel()
        pollingTask?.cancel()
        frontmostAppTask = nil
        systemStateTask = nil
        pollingTask = nil
    }

    private func runPollingLoop() async {
        while !Task.isCancelled {
            await pollOnce()
            signalAppliedProbe?(.poll)
            try? await Task.sleep(for: pollingInterval)
        }
    }

    private func pollOnce() async {
        let idleSeconds = idleTimeSource.secondsSinceLastEvent()
        await engine.handleIdleTimeSample(secondsSinceLastEvent: idleSeconds)

        let isTrusted = permissionSource.isTrusted()
        await engine.handleAccessibilityPermissionChanged(isTrusted: isTrusted)

        let reading = await windowTitleSource.currentWindowTitle()
        await engine.handleWindowTitleObserved(reading.title)
    }
}
