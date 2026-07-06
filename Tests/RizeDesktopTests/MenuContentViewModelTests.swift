@testable import RizeDesktop
import XCTest

/// Exercises `MenuContentViewModel` against stub `LocalStore`/
/// `TrackingEngineControlling` implementations — no GRDB, no real
/// `TrackingEngine` actor — covering the menu-bar dashboard's today
/// summary, top-apps aggregation, tracking-state presentation, and
/// permission-onboarding states from
/// `documentation/architecture-desktop.md` §Component Diagram and
/// §Permissions & Entitlements.
final class MenuContentViewModelTests: XCTestCase {
    /// Minimal `LocalStore` stub: only `fetchTodayActivity()` matters to the
    /// view model, so every other requirement is a no-op/empty stub.
    private actor StubLocalStore: LocalStore {
        var events: [ActivityEvent] = []
        var fetchError: Error?
        private(set) var fetchTodayActivityCallCount = 0

        init(events: [ActivityEvent] = []) {
            self.events = events
        }

        func writeEvent(_ event: ActivityEvent) async throws {}
        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}

        func fetchTodayActivity() async throws -> [ActivityEvent] {
            fetchTodayActivityCallCount += 1
            if let fetchError {
                throw fetchError
            }
            return events
        }

        func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
            []
        }

        func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {}

        func setFetchError(_ error: Error) {
            fetchError = error
        }
    }

    /// A settable `TrackingEngineControlling` stub, so tests can drive the
    /// view model through every lifecycle/permission/pause combination
    /// without the real state machine.
    private actor StubEngine: TrackingEngineControlling {
        var state: TrackingLifecycleState
        var permissionState: AccessibilityPermissionState
        var isPaused: Bool
        private(set) var pauseCallCount = 0
        private(set) var resumeCallCount = 0

        init(
            state: TrackingLifecycleState = .active,
            permissionState: AccessibilityPermissionState = .granted,
            isPaused: Bool = false
        ) {
            self.state = state
            self.permissionState = permissionState
            self.isPaused = isPaused
        }

        func pause() async {
            isPaused = true
            pauseCallCount += 1
        }

        func resume() async {
            isPaused = false
            resumeCallCount += 1
        }

        func setState(_ newState: TrackingLifecycleState) {
            state = newState
        }

        func setPermissionState(_ newState: AccessibilityPermissionState) {
            permissionState = newState
        }
    }

    private struct StubFetchError: Error {}

    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// Deterministically drains the cooperative scheduler so an unstructured
    /// `Task` started elsewhere (e.g. by `startAutoRefresh()`) gets to run
    /// its work — no wall-clock `Task.sleep`, so no CI flakiness. The loop
    /// bound is generous but finite: each `Task.yield()` gives every other
    /// runnable task on the executor a turn.
    private func megaYield(count: Int = 20) async {
        for _ in 0 ..< count {
            await Task.yield()
        }
    }

    private func makeAppActiveEvent(appBundleID: String, durationSeconds: TimeInterval) -> ActivityEvent {
        ActivityEvent(
            eventID: UUID(),
            startedAt: referenceDate,
            endedAt: referenceDate.addingTimeInterval(durationSeconds),
            type: .appActive,
            appBundleID: appBundleID,
            insertedAt: referenceDate
        )
    }

    // MARK: - Today summary / top apps

    func testRefreshPopulatesTotalTrackedTimeAndTopAppsFromStore() async {
        let editorEvent = makeAppActiveEvent(appBundleID: "com.acme.Editor", durationSeconds: 1800)
        let browserEvent = makeAppActiveEvent(appBundleID: "com.acme.Browser", durationSeconds: 600)
        let store = StubLocalStore(events: [editorEvent, browserEvent])
        let viewModel = MenuContentViewModel(store: store, engine: StubEngine())

        await viewModel.refresh()

        XCTAssertEqual(viewModel.totalTrackedTimeText, "40m")
        XCTAssertEqual(viewModel.topApps.map(\.bundleID), ["com.acme.Editor", "com.acme.Browser"])
    }

    func testRefreshWithNoActivityShowsZeroAndNoTopApps() async {
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: StubEngine())

        await viewModel.refresh()

        XCTAssertEqual(viewModel.totalTrackedTimeText, "0m")
        XCTAssertTrue(viewModel.topApps.isEmpty)
    }

    func testRefreshRespectsInjectedTopAppsLimit() async {
        let eventA = makeAppActiveEvent(appBundleID: "com.acme.A", durationSeconds: 300)
        let eventB = makeAppActiveEvent(appBundleID: "com.acme.B", durationSeconds: 200)
        let eventC = makeAppActiveEvent(appBundleID: "com.acme.C", durationSeconds: 100)
        let store = StubLocalStore(events: [eventA, eventB, eventC])
        let viewModel = MenuContentViewModel(store: store, engine: StubEngine(), topAppsLimit: 1)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.topApps.map(\.bundleID), ["com.acme.A"])
    }

    func testRefreshWhenStoreThrowsLeavesPreviousDataInPlace() async {
        let store = StubLocalStore(events: [makeAppActiveEvent(appBundleID: "com.acme.Editor", durationSeconds: 60)])
        let viewModel = MenuContentViewModel(store: store, engine: StubEngine())
        await viewModel.refresh()
        XCTAssertEqual(viewModel.totalTrackedTimeText, "1m")

        await store.setFetchError(StubFetchError())
        await viewModel.refresh()

        XCTAssertEqual(viewModel.totalTrackedTimeText, "1m")
    }

    // MARK: - Tracking state presentation

    func testRefreshPresentsActiveEngineStateAsTracking() async {
        let engine = StubEngine(state: .active)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.displayState, .tracking)
        XCTAssertFalse(viewModel.isPaused)
    }

    func testRefreshPresentsIdleEngineState() async {
        let engine = StubEngine(state: .idle)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.displayState, .idle)
    }

    func testRefreshPresentsLockedEngineState() async {
        let engine = StubEngine(state: .locked)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.displayState, .locked)
    }

    func testRefreshPresentsSleepingEngineState() async {
        let engine = StubEngine(state: .sleeping)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.displayState, .sleeping)
    }

    func testRefreshPausedOverridesLifecycleStateEvenWhenActive() async {
        let engine = StubEngine(state: .active, isPaused: true)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.displayState, .paused)
        XCTAssertTrue(viewModel.isPaused)
    }

    // MARK: - Pause / resume

    func testTogglePauseFromRunningPausesTheEngineAndRefreshes() async {
        let engine = StubEngine(state: .active, isPaused: false)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)
        await viewModel.refresh()
        XCTAssertFalse(viewModel.isPaused)

        await viewModel.togglePause()

        let pauseCalls = await engine.pauseCallCount
        XCTAssertEqual(pauseCalls, 1)
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertEqual(viewModel.displayState, .paused)
    }

    func testTogglePauseFromPausedResumesTheEngineAndRefreshes() async {
        let engine = StubEngine(state: .active, isPaused: true)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)
        await viewModel.refresh()
        XCTAssertTrue(viewModel.isPaused)

        await viewModel.togglePause()

        let resumeCalls = await engine.resumeCallCount
        XCTAssertEqual(resumeCalls, 1)
        XCTAssertFalse(viewModel.isPaused)
        XCTAssertEqual(viewModel.displayState, .tracking)
    }

    // MARK: - Permission onboarding

    func testShowsAccessibilityOnboardingWhenPermissionDenied() async {
        let engine = StubEngine(permissionState: .denied)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.showsAccessibilityOnboarding)
    }

    func testHidesAccessibilityOnboardingWhenPermissionGranted() async {
        let engine = StubEngine(permissionState: .granted)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)

        await viewModel.refresh()

        XCTAssertFalse(viewModel.showsAccessibilityOnboarding)
    }

    func testRefreshPicksUpPermissionStateChangesBetweenCalls() async {
        let engine = StubEngine(permissionState: .granted)
        let viewModel = MenuContentViewModel(store: StubLocalStore(), engine: engine)
        await viewModel.refresh()
        XCTAssertFalse(viewModel.showsAccessibilityOnboarding)

        await engine.setPermissionState(.denied)
        await viewModel.refresh()

        XCTAssertTrue(viewModel.showsAccessibilityOnboarding)
    }

    // MARK: - Refresh-loop lifecycle

    /// `startAutoRefresh()` runs an immediate `refresh()` before its first
    /// sleep. A very long interval keeps the loop parked in
    /// `Task.sleep(for:)` after that first pass for the rest of the test, so
    /// draining the scheduler with `megaYield()` observes exactly the one
    /// immediate refresh deterministically, without waiting on real time.
    func testStartAutoRefreshPerformsAnImmediateRefresh() async {
        let event = makeAppActiveEvent(appBundleID: "com.acme.Editor", durationSeconds: 120)
        let store = StubLocalStore(events: [event])
        let viewModel = MenuContentViewModel(store: store, engine: StubEngine())

        await viewModel.startAutoRefresh(interval: .seconds(3600))
        await megaYield()

        XCTAssertEqual(viewModel.totalTrackedTimeText, "2m")
        let callCount = await store.fetchTodayActivityCallCount
        XCTAssertEqual(callCount, 1)

        await viewModel.stopAutoRefresh()
    }

    /// `stopAutoRefresh()` cancels the loop's `Task` while it's parked in
    /// `Task.sleep(for:)`: cancellation makes the sleep throw, and the
    /// `while !Task.isCancelled` check then exits the loop before it can
    /// perform another `refresh()`. Draining the scheduler again after
    /// stopping and asserting the store's call count is unchanged is an
    /// observable proxy for "no further mutations" — `refreshTask` itself is
    /// a private implementation detail not exposed to tests.
    func testStopAutoRefreshCancelsTheLoopAndPreventsFurtherRefreshes() async {
        let event = makeAppActiveEvent(appBundleID: "com.acme.Editor", durationSeconds: 120)
        let store = StubLocalStore(events: [event])
        let viewModel = MenuContentViewModel(store: store, engine: StubEngine())

        await viewModel.startAutoRefresh(interval: .seconds(3600))
        await megaYield()
        let callCountAfterStart = await store.fetchTodayActivityCallCount
        XCTAssertEqual(callCountAfterStart, 1)

        await viewModel.stopAutoRefresh()
        await megaYield()

        let callCountAfterStop = await store.fetchTodayActivityCallCount
        XCTAssertEqual(callCountAfterStop, 1)
    }
}
