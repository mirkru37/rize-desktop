import Foundation
import Observation

/// Drives the menu-bar dashboard: today's tracked time and top apps (read
/// from `LocalStore`), the live tracking/permission state (read from the
/// Tracking Engine), and the pause/resume control, per
/// `documentation/architecture-desktop.md` §Component Diagram and
/// §Permissions & Entitlements.
///
/// Depends only on `LocalStore` and `TrackingEngineControlling` — both
/// protocols — so it is exercised in tests with stubs rather than the real
/// GRDB store and the tracking actor. `@MainActor`-isolated so its
/// `@Observable` properties are only ever mutated on the main actor — the
/// same actor `MenuContentView` reads them from — even though `refresh()`
/// awaits off-actor work on `store`/`engine` in between.
@MainActor
@Observable
final class MenuContentViewModel {
    private(set) var totalTrackedTimeText = ActivityAggregation.formatDuration(0)
    private(set) var topApps: [ActivityAggregation.AppUsage] = []
    private(set) var displayState = TrackingDisplayState(lifecycleState: .active, isPaused: false)
    private(set) var permissionState: AccessibilityPermissionState = .granted

    var isPaused: Bool {
        displayState == .paused
    }

    /// Whether the Accessibility-permission onboarding explanation should be
    /// shown, per `documentation/architecture-desktop.md` §Permissions &
    /// Entitlements.
    var showsAccessibilityOnboarding: Bool {
        permissionState == .denied
    }

    /// The auth/sync-status facades for the menu's sign-in sheet and sync
    /// status row (RIZ-41). `nil` in contexts that don't wire up sync (e.g.
    /// existing previews/tests predating RIZ-41), in which case the menu
    /// simply omits that UI.
    let authSession: AuthSessionViewModel?
    let syncStatus: SyncStatusViewModel?

    private let store: LocalStore
    private let engine: TrackingEngineControlling
    private let topAppsLimit: Int
    private var refreshTask: Task<Void, Never>?

    init(
        store: LocalStore,
        engine: TrackingEngineControlling,
        topAppsLimit: Int = 3,
        authSession: AuthSessionViewModel? = nil,
        syncStatus: SyncStatusViewModel? = nil
    ) {
        self.store = store
        self.engine = engine
        self.topAppsLimit = topAppsLimit
        self.authSession = authSession
        self.syncStatus = syncStatus
    }

    /// Re-reads today's activity from the store and the engine's live state,
    /// and updates the published presentation properties. Safe to call
    /// repeatedly (e.g. from a menu-open refresh timer).
    func refresh() async {
        let lifecycleState = await engine.state
        let enginePaused = await engine.isPaused
        permissionState = await engine.permissionState
        displayState = TrackingDisplayState(lifecycleState: lifecycleState, isPaused: enginePaused)

        guard let events = try? await store.fetchTodayActivity() else {
            return
        }
        let summary = ActivityAggregation.summarize(events: events, topAppsLimit: topAppsLimit)
        totalTrackedTimeText = ActivityAggregation.formatDuration(summary.totalTrackedTime)
        topApps = summary.topApps
    }

    /// Starts a periodic `refresh()` loop while the menu is open; call
    /// `stopAutoRefresh()` when it closes. An immediate refresh runs before
    /// the first sleep, so the menu shows current data as soon as it opens.
    func startAutoRefresh(interval: Duration = .seconds(5)) {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Cancels the periodic refresh loop started by `startAutoRefresh()`.
    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Toggles the engine's pause state and immediately reflects the result.
    func togglePause() async {
        if isPaused {
            await engine.resume()
        } else {
            await engine.pause()
        }
        await refresh()
    }
}
