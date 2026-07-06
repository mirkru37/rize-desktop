import Foundation

/// A single frontmost-application sample. `bundleID` is `nil` when no app
/// could be identified (e.g. the frontmost process has no bundle
/// identifier).
struct FrontmostAppSample: Equatable {
    var bundleID: String?
}

/// Source of frontmost-application activation events, per
/// `documentation/architecture-desktop.md` §Tracking Pipeline
/// (`NSWorkspace`'s `didActivateApplicationNotification` in production).
/// Injected behind a protocol so the Tracking Engine can be driven by a
/// simulated sequence of samples in tests.
protocol FrontmostAppSignalSource: Sendable {
    /// A stream of samples, one per app activation. Implementations should
    /// yield an initial sample for the currently-frontmost app immediately
    /// so the engine is seeded before the first notification arrives.
    func events() -> AsyncStream<FrontmostAppSample>
}

/// Which path a window-title reading came from, per
/// `documentation/architecture-desktop.md` §Tracking Pipeline and
/// §Permissions & Entitlements.
enum WindowTitlePath: Equatable {
    /// The Accessibility API resolved the focused window's title.
    case accessibility
    /// The Accessibility API was unavailable; `CGWindowList` resolved it.
    case cgWindowListFallback
    /// Neither path could resolve a title (permissions denied, or the API
    /// call failed).
    case unavailable
}

/// A single window-title poll result.
struct WindowTitleReading: Equatable {
    var title: String?
    var path: WindowTitlePath
}

/// Polled by the Tracking Engine's window-title loop (every 1-5 seconds per
/// the doc) to resolve the focused window's title. Injected behind a
/// protocol so segmentation on title changes is testable without a live
/// Accessibility session.
protocol WindowTitleSignalSource: Sendable {
    /// `async` because resolving the reading requires reading
    /// `NSWorkspace.shared.frontmostApplication` on the main actor; the
    /// polling loop that calls this runs off the main thread.
    func currentWindowTitle() async -> WindowTitleReading
}

/// Reports elapsed system idle time, used to drive the `active -> idle`
/// transition (`CGEventSource` in production).
protocol IdleTimeSignalSource: Sendable {
    func secondsSinceLastEvent() -> TimeInterval
}

/// System-level signals that force a state-machine transition regardless of
/// idle time, per `documentation/architecture-desktop.md` §Tracking State
/// Machine.
enum SystemStateSignal: Equatable {
    case screenLocked
    case screenUnlocked
    case willSleep
    case didWake
}

/// Source of the lock/unlock and sleep/wake signals above (a distributed
/// notification for screen lock state, `NSWorkspace` sleep notifications for
/// the rest, in production).
protocol SystemStateSignalSource: Sendable {
    func events() -> AsyncStream<SystemStateSignal>
}

/// Whether the Accessibility permission required for the primary
/// window-title path is currently granted. Exposed by the Tracking Engine
/// to the UI layer so onboarding can prompt the user, per
/// `documentation/architecture-desktop.md` §Permissions & Entitlements.
enum AccessibilityPermissionState: Equatable {
    case granted
    case denied
}

/// Checks the live Accessibility permission (`AXIsProcessTrusted` in
/// production).
protocol AccessibilityPermissionSource: Sendable {
    func isTrusted() -> Bool
}
