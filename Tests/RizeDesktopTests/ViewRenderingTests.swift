@testable import RizeDesktop
import XCTest

/// Smoke-renders `LoginView`/`MenuContentView` by evaluating their `body`
/// against stub view models covering every branch (signed-in/out, sync
/// states, permission onboarding, top-apps list, error message), rather
/// than asserting on specific rendered output — SwiftUI's `View` protocol
/// gives tests no supported way to inspect a rendered tree, so this
/// exercises the same view-construction code paths the app runs without
/// coupling to SwiftUI internals. Per the RIZ-67 coverage brief, these two
/// files had 0% coverage despite containing real branching logic
/// (`syncStatusText`, `authAndSyncSection`, `accessibilityOnboarding`).
@MainActor
final class ViewRenderingTests: XCTestCase {
    // MARK: - Test doubles

    private actor StubLocalStore: LocalStore {
        private let events: [ActivityEvent]

        init(events: [ActivityEvent] = []) {
            self.events = events
        }

        func writeEvent(_ event: ActivityEvent) async throws {}
        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}
        func tombstoneSession(id: UUID, at date: Date) async throws {}

        func fetchTodayActivity() async throws -> [ActivityEvent] {
            events
        }

        func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
            []
        }

        func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {}
    }

    private actor StubEngine: TrackingEngineControlling {
        let state: TrackingLifecycleState
        let permissionState: AccessibilityPermissionState
        let isPaused: Bool

        init(
            state: TrackingLifecycleState = .active,
            permissionState: AccessibilityPermissionState = .granted,
            isPaused: Bool = false
        ) {
            self.state = state
            self.permissionState = permissionState
            self.isPaused = isPaused
        }

        func pause() async {}
        func resume() async {}
    }

    private func makeAppUsageEvent(bundleID: String, seconds: TimeInterval) -> ActivityEvent {
        let now = Date()
        return ActivityEvent(
            eventID: UUID(),
            startedAt: now.addingTimeInterval(-seconds),
            endedAt: now,
            type: .appActive,
            appBundleID: bundleID,
            insertedAt: now
        )
    }

    // MARK: - LoginView

    func testLoginViewRendersIdleState() {
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager())
        let view = LoginView(authSession: viewModel, onFinished: {})

        _ = view.body
    }

    func testLoginViewRendersErrorMessageState() async {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.failure(APIError.unauthorized(nil)))
        let viewModel = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))
        await viewModel.login(email: "user@example.com", password: "wrong")
        XCTAssertNotNil(viewModel.errorMessage)

        let view = LoginView(authSession: viewModel, onFinished: {})

        _ = view.body
    }

    // MARK: - MenuContentView

    func testMenuContentViewRendersSignedOutWithoutTopAppsOrOnboarding() async {
        let store = StubLocalStore()
        let engine = StubEngine()
        let authSession = AuthSessionViewModel(tokenManager: makeAuthTokenManager())
        let syncStatus = SyncStatusViewModel()
        let viewModel = MenuContentViewModel(
            store: store,
            engine: engine,
            authSession: authSession,
            syncStatus: syncStatus
        )
        await viewModel.refresh()
        XCTAssertFalse(viewModel.showsAccessibilityOnboarding)
        XCTAssertTrue(viewModel.topApps.isEmpty)
        XCTAssertFalse(authSession.isSignedIn)

        let view = MenuContentView(viewModel: viewModel)

        _ = view.body
    }

    func testMenuContentViewRendersSignedInWithTopAppsSyncingAndOnboarding() async {
        let events = [
            makeAppUsageEvent(bundleID: "com.example.one", seconds: 120),
            makeAppUsageEvent(bundleID: "com.example.two", seconds: 60)
        ]
        let store = StubLocalStore(events: events)
        let engine = StubEngine(state: .active, permissionState: .denied, isPaused: true)
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.success(makeAuthResponse(accessToken: "access-1")))
        let authSession = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))
        await authSession.login(email: "user@example.com", password: "correct-horse-battery-staple")
        let syncStatus = SyncStatusViewModel()
        syncStatus.willStartCycle()
        let viewModel = MenuContentViewModel(
            store: store,
            engine: engine,
            authSession: authSession,
            syncStatus: syncStatus
        )
        await viewModel.refresh()
        XCTAssertTrue(viewModel.showsAccessibilityOnboarding)
        XCTAssertFalse(viewModel.topApps.isEmpty)
        XCTAssertTrue(viewModel.isPaused)
        XCTAssertTrue(authSession.isSignedIn)
        XCTAssertTrue(syncStatus.isSyncing)

        let view = MenuContentView(viewModel: viewModel)

        _ = view.body
    }

    func testMenuContentViewRendersSignedInWithLastSyncedAndSyncFailureStatusText() async {
        let store = StubLocalStore()
        let engine = StubEngine()
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.success(makeAuthResponse(accessToken: "access-1")))
        let authSession = AuthSessionViewModel(tokenManager: makeAuthTokenManager(api: api))
        await authSession.login(email: "user@example.com", password: "correct-horse-battery-staple")

        let syncedStatus = SyncStatusViewModel()
        syncedStatus.didFinishCycle(at: Date())
        let syncedViewModel = MenuContentViewModel(
            store: store,
            engine: engine,
            authSession: authSession,
            syncStatus: syncedStatus
        )
        await syncedViewModel.refresh()
        _ = MenuContentView(viewModel: syncedViewModel).body

        let failedStatus = SyncStatusViewModel()
        failedStatus.didFail(TestError.network)
        let failedViewModel = MenuContentViewModel(
            store: store,
            engine: engine,
            authSession: authSession,
            syncStatus: failedStatus
        )
        await failedViewModel.refresh()
        _ = MenuContentView(viewModel: failedViewModel).body

        let noSyncViewModel = MenuContentViewModel(store: store, engine: engine, authSession: authSession)
        await noSyncViewModel.refresh()
        _ = MenuContentView(viewModel: noSyncViewModel).body
    }
}
