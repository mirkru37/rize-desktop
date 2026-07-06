@testable import RizeDesktop
import XCTest

/// Exercises the Tracking Engine's state machine and event segmentation
/// (`documentation/architecture-desktop.md` §Tracking Pipeline, §Tracking
/// State Machine, §Event Model) with simulated signal sequences fed
/// directly through its `handle*` methods — no GUI session, no real
/// `NSWorkspace`/Accessibility/`CGEventSource`, no sleeps.
final class TrackingEngineTests: XCTestCase {
    /// A clock the test can advance explicitly, so segment durations are
    /// deterministic instead of depending on wall-clock time between calls.
    private final class MutableClock: Clock, @unchecked Sendable {
        private(set) var date: Date
        init(date: Date) {
            self.date = date
        }

        func now() -> Date {
            date
        }

        func advance(by seconds: TimeInterval) {
            date = date.addingTimeInterval(seconds)
        }
    }

    /// Records every event the engine writes, and can be told to fail
    /// writes to exercise the engine's error-handling path.
    private actor FakeLocalStore: LocalStore {
        private(set) var writtenEvents: [ActivityEvent] = []
        var writeError: Error?

        func writeEvent(_ event: ActivityEvent) async throws {
            if let writeError {
                throw writeError
            }
            writtenEvents.append(event)
        }

        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}
        func fetchTodayActivity() async throws -> [ActivityEvent] {
            writtenEvents
        }

        func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
            []
        }

        func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {}

        func setWriteError(_ error: Error) {
            writeError = error
        }
    }

    private struct TestStoreError: Error {}

    private var referenceDate: Date!
    private var clock: MutableClock!
    private var store: FakeLocalStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
        clock = MutableClock(date: referenceDate)
        store = FakeLocalStore()
    }

    override func tearDown() {
        referenceDate = nil
        clock = nil
        store = nil
        super.tearDown()
    }

    private func makeEngine(
        idleThreshold: TimeInterval = 300,
        minimumEventDuration: TimeInterval = 5,
        privacySettings: TrackingPrivacySettings = .defaultSettings
    ) -> TrackingEngine {
        TrackingEngine(
            store: store,
            clock: clock,
            idleThreshold: idleThreshold,
            minimumEventDuration: minimumEventDuration,
            privacySettings: privacySettings
        )
    }

    // MARK: - App switch segmentation

    func testAppSwitchClosesPreviousSegmentAndOpensNew() async {
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Terminal")
        await engine.handleWindowTitleObserved("Terminal — bash")
        clock.advance(by: 10)
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Safari")

        let events = await store.writtenEvents
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, .appActive)
        XCTAssertEqual(events[0].appBundleID, "com.apple.Terminal")
        XCTAssertEqual(events[0].windowTitle, "Terminal — bash")
        XCTAssertEqual(events[0].endedAt.timeIntervalSince(events[0].startedAt), 10, accuracy: 0.001)
    }

    func testSegmentsShorterThanMinimumDurationAreDiscarded() async {
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Terminal")
        // No clock advance: this segment is 0s long, well under the 5s floor.
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Safari")
        clock.advance(by: 10)
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Mail")

        let events = await store.writtenEvents
        XCTAssertEqual(events.map(\.appBundleID), ["com.apple.Safari"])
    }

    func testWindowTitleChangeWithinSameAppSegmentsSeparately() async {
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Safari")
        await engine.handleWindowTitleObserved("Tab A")
        clock.advance(by: 8)
        await engine.handleWindowTitleObserved("Tab B")
        clock.advance(by: 6)
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Mail")

        let events = await store.writtenEvents
        XCTAssertEqual(events.map(\.windowTitle), ["Tab A", "Tab B"])
        XCTAssertEqual(events.map(\.appBundleID), ["com.apple.Safari", "com.apple.Safari"])
    }

    // MARK: - Idle in/out

    func testIdleTransitionClosesActiveSegmentAndOpensIdleSegment() async {
        let engine = makeEngine(idleThreshold: 300)

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Editor")
        clock.advance(by: 350)
        await engine.handleIdleTimeSample(secondsSinceLastEvent: 320)
        clock.advance(by: 60)
        await engine.handleIdleTimeSample(secondsSinceLastEvent: 5)

        let events = await store.writtenEvents
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].type, .appActive)
        XCTAssertEqual(events[0].precision, .exact)
        XCTAssertEqual(events[0].endedAt.timeIntervalSince(events[0].startedAt), 350, accuracy: 0.001)
        XCTAssertEqual(events[1].type, .idle)
        XCTAssertEqual(events[1].precision, .approximate)
        XCTAssertNil(events[1].appBundleID)
        XCTAssertEqual(events[1].endedAt.timeIntervalSince(events[1].startedAt), 60, accuracy: 0.001)
        let state = await engine.state
        XCTAssertEqual(state, .active)
    }

    func testIdleSampleBelowThresholdWhileActiveDoesNotTransition() async {
        let engine = makeEngine(idleThreshold: 300)

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Editor")
        clock.advance(by: 10)
        await engine.handleIdleTimeSample(secondsSinceLastEvent: 2)

        let state = await engine.state
        XCTAssertEqual(state, .active)
        let events = await store.writtenEvents
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Lock / sleep

    func testScreenLockTransitionWritesLockedEvent() async {
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Editor")
        clock.advance(by: 20)
        await engine.handleSystemStateSignal(.screenLocked)
        clock.advance(by: 40)
        await engine.handleSystemStateSignal(.screenUnlocked)

        let events = await store.writtenEvents
        XCTAssertEqual(events.map(\.type), [.appActive, .locked])
        XCTAssertEqual(events[1].precision, .exact)
        XCTAssertEqual(events[1].endedAt.timeIntervalSince(events[1].startedAt), 40, accuracy: 0.001)
        let state = await engine.state
        XCTAssertEqual(state, .active)
    }

    func testSleepWakeCycleIsPersistedAsAnIdleTypeEvent() async {
        // The local schema's `type` check constraint has no dedicated
        // "sleeping" value (documentation/database-schema.md
        // §activity_events), so a sleep/wake cycle is recorded as `.idle`:
        // an assumption documented in this ticket's PR.
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Editor")
        clock.advance(by: 20)
        await engine.handleSystemStateSignal(.willSleep)
        clock.advance(by: 500)
        await engine.handleSystemStateSignal(.didWake)

        let events = await store.writtenEvents
        XCTAssertEqual(events.map(\.type), [.appActive, .idle])
        XCTAssertEqual(events[1].precision, .approximate)
        XCTAssertEqual(events[1].endedAt.timeIntervalSince(events[1].startedAt), 500, accuracy: 0.001)
    }

    // MARK: - Permissions

    func testAccessibilityPermissionStateIsExposedForTheUILayer() async {
        let engine = makeEngine()

        let initial = await engine.permissionState
        XCTAssertEqual(initial, .granted)

        await engine.handleAccessibilityPermissionChanged(isTrusted: false)
        let denied = await engine.permissionState
        XCTAssertEqual(denied, .denied)

        await engine.handleAccessibilityPermissionChanged(isTrusted: true)
        let granted = await engine.permissionState
        XCTAssertEqual(granted, .granted)
    }

    func testMissingWindowTitleStillProducesAppLevelSegment() async {
        // Simulates degraded tracking when Accessibility/Screen Recording
        // are both denied: the Window Inspector reports no title, but
        // app-level tracking continues per §Permissions & Entitlements.
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Editor")
        await engine.handleWindowTitleObserved(nil)
        clock.advance(by: 10)
        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Other")

        let events = await store.writtenEvents
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].appBundleID, "com.acme.Editor")
        XCTAssertNil(events[0].windowTitle)
    }

    // MARK: - Privacy controls

    func testExcludedAppProducesNoActivityEvent() async {
        let settings = TrackingPrivacySettings(
            excludedBundleIDs: ["com.acme.Private"],
            captureWindowTitles: true,
            privateTitleMarkers: []
        )
        let engine = makeEngine(privacySettings: settings)

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Private")
        clock.advance(by: 30)
        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Other")

        let events = await store.writtenEvents
        XCTAssertTrue(events.isEmpty)
    }

    func testWindowTitleCaptureToggleOffKeepsTitlesNil() async {
        let settings = TrackingPrivacySettings(
            excludedBundleIDs: [],
            captureWindowTitles: false,
            privateTitleMarkers: []
        )
        let engine = makeEngine(privacySettings: settings)

        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Safari")
        await engine.handleWindowTitleObserved("Tab A")
        clock.advance(by: 10)
        await engine.handleWindowTitleObserved("Tab B")
        clock.advance(by: 10)
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Mail")

        let events = await store.writtenEvents
        // Title-only changes never split the segment when capture is off.
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].windowTitle)
        XCTAssertEqual(events[0].endedAt.timeIntervalSince(events[0].startedAt), 20, accuracy: 0.001)
    }

    func testPrivateWindowTitleIsFilteredOut() async {
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Safari")
        await engine.handleWindowTitleObserved("My Bank — Private Browsing")
        clock.advance(by: 10)
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Mail")

        let events = await store.writtenEvents
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].windowTitle)
    }

    // MARK: - Persistence failure

    func testPersistenceFailureIsRecordedRatherThanThrown() async {
        let engine = makeEngine()
        await store.setWriteError(TestStoreError())

        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Terminal")
        clock.advance(by: 10)
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Safari")

        let events = await store.writtenEvents
        XCTAssertTrue(events.isEmpty)
        let lastError = await engine.lastPersistenceError
        XCTAssertNotNil(lastError)
    }
}
