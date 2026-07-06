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

        init(events: [ActivityEvent] = []) {
            self.events = events
        }

        func writeEvent(_ event: ActivityEvent) async throws {}
        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}

        func fetchTodayActivity() async throws -> [ActivityEvent] {
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
        let store = StubLocalStore(events: [
            makeAppActiveEvent(appBundleID: "com.acme.Editor", durationSeconds: 1800),
            makeAppActiveEvent(appBundleID: "com.acme.Browser", durationSeconds: 600),
        ])
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
        let store = StubLocalStore(events: [
            makeAppActiveEvent(appBundleID: "com.acme.A", durationSeconds: 300),
            makeAppActiveEvent(appBundleID: "com.acme.B", durationSeconds: 200),
            makeAppActiveEvent(appBundleID: "com.acme.C", durationSeconds: 100),
        ])
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
}
