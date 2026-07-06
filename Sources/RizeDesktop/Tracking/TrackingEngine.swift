import Foundation

/// The Tracking Engine's activity state, per
/// `documentation/architecture-desktop.md` §Tracking State Machine.
enum TrackingLifecycleState: Equatable {
    case active
    case idle
    case locked
    case sleeping
}

/// What the currently-open segment represents. Distinct from
/// `TrackingLifecycleState` because `.active` further branches on whether a
/// frontmost app is known and whether it is excluded from tracking.
private enum SegmentKind: Equatable {
    case tracking(appBundleID: String, windowTitle: String?)
    case idle
    case locked
    case sleeping
    /// Frontmost app is on the exclusion list; never persisted.
    case excluded
    /// State is `.active` but no frontmost app has been observed yet; never
    /// persisted.
    case unknown
    /// The user paused tracking from the menu-bar UI; never persisted.
    case paused
}

/// An in-progress activity segment, not yet closed into an `ActivityEvent`.
private struct OpenSegment {
    var startedAt: Date
    var kind: SegmentKind
}

/// Drives the automatic tracking state machine and event segmentation
/// described in `documentation/architecture-desktop.md` §Tracking Pipeline,
/// §Tracking State Machine, and §Event Model.
///
/// The engine is a pure consumer of OS signals delivered through the
/// `handle*` methods below; it has no dependency on `NSWorkspace`,
/// Accessibility, or `CGEventSource` directly, which is what makes it
/// unit-testable with simulated signal sequences. `TrackingCoordinator`
/// wires the real OS-backed signal sources to these methods; tests call
/// them directly with a fixed/mutable `Clock`.
///
/// An actor because signals arrive concurrently from independent sources
/// (app-activation notifications, the title/idle polling loop, distributed
/// lock/sleep notifications); actor isolation serializes them without
/// requiring a separate locking scheme.
actor TrackingEngine {
    private let store: LocalStore
    private let clock: Clock
    private let idleThreshold: TimeInterval
    private let minimumEventDuration: TimeInterval

    private(set) var state: TrackingLifecycleState = .active
    private(set) var permissionState: AccessibilityPermissionState = .granted
    private(set) var lastPersistenceError: Error?
    /// Whether the user has paused tracking from the menu-bar UI. Distinct
    /// from `state`: pausing does not change the underlying lifecycle state
    /// (idle/locked/sleeping detection keeps running), it just stops
    /// `computeSegmentKind()` from producing a persistable segment.
    private(set) var isPaused = false

    private var privacySettings: TrackingPrivacySettings
    private var currentAppBundleID: String?
    private var currentWindowTitle: String?
    private var openSegment: OpenSegment?

    /// - Parameters:
    ///   - store: Where closed segments are written as `activity_events`.
    ///   - clock: Injected so segment boundaries and `insertedAt` are
    ///     deterministic in tests.
    ///   - idleThreshold: Seconds of no input before `active -> idle`.
    ///     Defaults to 300s per the doc.
    ///   - minimumEventDuration: Segments shorter than this are discarded as
    ///     noise rather than written. Defaults to 5s per the doc.
    init(
        store: LocalStore,
        clock: Clock = SystemClock(),
        idleThreshold: TimeInterval = 300,
        minimumEventDuration: TimeInterval = 5,
        privacySettings: TrackingPrivacySettings = .defaultSettings
    ) {
        self.store = store
        self.clock = clock
        self.idleThreshold = idleThreshold
        self.minimumEventDuration = minimumEventDuration
        self.privacySettings = privacySettings
    }

    /// Applies updated Settings-sourced privacy controls immediately,
    /// re-evaluating the currently-open segment against them.
    func updatePrivacySettings(_ settings: TrackingPrivacySettings) async {
        privacySettings = settings
        await reconcileSegment()
    }

    /// Fed by `NSWorkspace`'s `didActivateApplicationNotification`.
    func handleFrontmostAppChanged(bundleID: String?) async {
        guard bundleID != currentAppBundleID else {
            return
        }
        currentAppBundleID = bundleID
        currentWindowTitle = nil
        await reconcileSegment()
    }

    /// Fed by the Window Inspector's polling loop.
    func handleWindowTitleObserved(_ rawTitle: String?) async {
        let title = filteredTitle(rawTitle)
        guard title != currentWindowTitle else {
            return
        }
        currentWindowTitle = title
        await reconcileSegment()
    }

    /// Fed by `CGEventSource.secondsSinceLastEventType` on the polling loop.
    func handleIdleTimeSample(secondsSinceLastEvent seconds: TimeInterval) async {
        switch state {
        case .active where seconds > idleThreshold:
            // Back-date the active -> idle boundary to the true last-input
            // instant rather than detection time: the user actually went
            // idle `seconds` ago, so the active segment should not include
            // the idle time it took the poller to notice. See RIZ-39
            // review, finding M1. `closeSegmentAndAdvance` clamps this to
            // the active segment's `startedAt` if it would otherwise
            // precede it.
            let lastInputInstant = clock.now().addingTimeInterval(-seconds)
            await transition(to: .idle, boundary: lastInputInstant)
        case .idle where seconds < idleThreshold:
            await transition(to: .active)
        default:
            break
        }
    }

    /// Fed by the distributed lock notification and `NSWorkspace`
    /// sleep/wake notifications.
    func handleSystemStateSignal(_ signal: SystemStateSignal) async {
        switch signal {
        case .screenLocked:
            await transition(to: .locked)
        case .screenUnlocked, .didWake:
            await transition(to: .active)
        case .willSleep:
            await transition(to: .sleeping)
        }
    }

    /// Fed by a periodic `AXIsProcessTrusted()` check.
    func handleAccessibilityPermissionChanged(isTrusted: Bool) {
        permissionState = isTrusted ? .granted : .denied
    }

    /// Stops producing persistable segments until `resume()` is called, per
    /// the menu-bar UI's pause control. `isPaused` is set synchronously
    /// before the only `await` below, matching the `updatePrivacySettings`
    /// pattern above — no state mutation happens across a suspension point
    /// (RIZ-39 review, finding H1).
    func pause() async {
        isPaused = true
        await reconcileSegment()
    }

    /// Resumes producing persistable segments after `pause()`.
    func resume() async {
        isPaused = false
        await reconcileSegment()
    }

    // MARK: - State machine

    /// - Parameter boundary: Overrides the segment boundary used to close
    ///   the outgoing segment and open the incoming one. Defaults to
    ///   `clock.now()` (detection time); the active -> idle transition
    ///   passes a back-dated last-input instant instead (finding M1).
    private func transition(to newState: TrackingLifecycleState, boundary: Date? = nil) async {
        guard newState != state else {
            return
        }
        state = newState
        // Returning to `.active` from idle/locked/sleeping closes the gap
        // segment as its own event; the brief's two back-fill options
        // (discard vs. prompt-to-attribute) are both "close the gap as-is
        // and let something else decide what to do with it" from the
        // engine's point of view. No attribution UI exists yet, so the
        // effective behavior today is discard.
        await reconcileSegment(boundary: boundary)
    }

    private func filteredTitle(_ rawTitle: String?) -> String? {
        guard privacySettings.captureWindowTitles, let rawTitle else {
            return nil
        }
        guard !privacySettings.isPrivateTitle(rawTitle) else {
            return nil
        }
        return rawTitle
    }

    private func computeSegmentKind() -> SegmentKind {
        guard !isPaused else {
            return .paused
        }
        switch state {
        case .active:
            guard let bundleID = currentAppBundleID else {
                return .unknown
            }
            guard !privacySettings.isExcluded(bundleID) else {
                return .excluded
            }
            return .tracking(appBundleID: bundleID, windowTitle: currentWindowTitle)
        case .idle:
            return .idle
        case .locked:
            return .locked
        case .sleeping:
            return .sleeping
        }
    }

    // MARK: - Segmentation

    /// Closes the current segment (if any) and opens the next one, then
    /// persists the closed segment's event.
    ///
    /// All in-memory segment state — reading the closing segment, deciding
    /// whether it's long enough to keep, and swapping in the new
    /// `openSegment` — happens synchronously in `closeSegmentAndAdvance`,
    /// with no `await` in between. Only the persistence call below
    /// suspends. This matters because `TrackingEngine` is an actor: any
    /// `await` inside this method is a reentrancy point where another
    /// queued signal (e.g. a competing app switch) can run before this call
    /// resumes. Previously `openSegment` was assigned *after* awaiting the
    /// store write, so a reentrant call could set its own `openSegment`
    /// during that suspension, only for this call to resume and clobber it
    /// with stale data — losing switches and producing non-monotonic
    /// timestamps. See RIZ-39 review, finding H1.
    private func reconcileSegment(boundary: Date? = nil) async {
        let newKind = computeSegmentKind()
        guard newKind != openSegment?.kind else {
            return
        }
        guard let event = closeSegmentAndAdvance(to: newKind, at: boundary ?? clock.now()) else {
            return
        }
        await persist(event)
    }

    /// Synchronously closes the currently-open segment (if long enough to
    /// keep) and replaces it with a new segment of `newKind` starting at
    /// the boundary. Returns the closed segment's event, if any, for the
    /// caller to persist. Contains no suspension points.
    ///
    /// `requestedBoundary` may be back-dated (finding M1's idle boundary).
    /// It's clamped to the closing segment's `startedAt` so a boundary that
    /// precedes the segment's start can never produce a negative-duration
    /// event; if the clamped duration is under the minimum, the segment is
    /// dropped as noise rather than persisted, exactly as an ordinary
    /// too-short segment would be.
    private func closeSegmentAndAdvance(to newKind: SegmentKind, at requestedBoundary: Date) -> ActivityEvent? {
        let closingSegment = openSegment
        let boundary = closingSegment.map { max(requestedBoundary, $0.startedAt) } ?? requestedBoundary
        openSegment = OpenSegment(startedAt: boundary, kind: newKind)

        guard let closingSegment else {
            return nil
        }
        guard boundary.timeIntervalSince(closingSegment.startedAt) >= minimumEventDuration else {
            return nil
        }
        return makeActivityEvent(for: closingSegment.kind, startedAt: closingSegment.startedAt, endedAt: boundary)
    }

    private func persist(_ event: ActivityEvent) async {
        do {
            try await store.writeEvent(event)
        } catch {
            lastPersistenceError = error
        }
    }

    private func makeActivityEvent(for kind: SegmentKind, startedAt: Date, endedAt: Date) -> ActivityEvent? {
        let type: ActivityEventType
        let precision: ActivityEventPrecision
        var appBundleID: String?
        var windowTitle: String?

        switch kind {
        case let .tracking(bundleID, title):
            type = .appActive
            precision = .exact
            appBundleID = bundleID
            windowTitle = title
        case .idle, .sleeping:
            type = .idle
            precision = .approximate
        case .locked:
            type = .locked
            precision = .exact
        case .excluded, .unknown, .paused:
            return nil
        }

        return ActivityEvent(
            eventID: UUIDv7.generate(),
            startedAt: startedAt,
            endedAt: endedAt,
            type: type,
            precision: precision,
            appBundleID: appBundleID,
            windowTitle: windowTitle,
            insertedAt: clock.now()
        )
    }
}
