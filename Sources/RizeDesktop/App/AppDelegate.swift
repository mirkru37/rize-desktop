import AppKit
import SwiftUI

/// Owns the `NSStatusItem` menu-bar shell. `MenuBarExtra` is intentionally not
/// used here — see `documentation/system-overview.md` for the rationale
/// (AppKit's `NSStatusItem` gives full control over the menu-bar item).
///
/// `@MainActor`-isolated: AppKit already invokes every delegate callback here
/// (`applicationDidFinishLaunching`, `menuWillOpen`/`menuDidClose`) on the
/// main thread, and this annotation lets the compiler enforce it — which is
/// also what makes constructing the `@MainActor`-isolated
/// `MenuContentViewModel` in `configureStatusItem(tracking:)` valid.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var trackingEngine: TrackingEngine?
    private var trackingCoordinator: TrackingCoordinator?
    private var menuContentViewModel: MenuContentViewModel?
    private var syncCoordinator: SyncCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tracking = startTracking()
        let sync = tracking.map { startSync(store: $0.store) }
        configureStatusItem(tracking: tracking, sync: sync)
    }

    /// Builds the menu-bar dashboard described in
    /// `documentation/architecture-desktop.md` §Component Diagram: a
    /// SwiftUI `MenuContentView` hosted inside the status item's menu,
    /// followed by a Quit item. `tracking` is `nil` if the local store
    /// failed to open (see `startTracking()`) — the dashboard is simply
    /// omitted in that case rather than crashing the menu-bar shell.
    private func configureStatusItem(
        tracking: (engine: TrackingEngine, store: LocalStore)?,
        sync: (authSession: AuthSessionViewModel, syncStatus: SyncStatusViewModel)?
    ) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "RizeClone"
        )

        let menu = NSMenu()
        menu.delegate = self

        if let tracking {
            let viewModel = MenuContentViewModel(
                store: tracking.store,
                engine: tracking.engine,
                authSession: sync?.authSession,
                syncStatus: sync?.syncStatus
            )
            menuContentViewModel = viewModel
            menu.addItem(makeContentMenuItem(viewModel: viewModel))
            menu.addItem(.separator())
        }

        let quitMenuItem = NSMenuItem(
            title: "Quit RizeClone",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitMenuItem)

        item.menu = menu
        statusItem = item
    }

    private func makeContentMenuItem(viewModel: MenuContentViewModel) -> NSMenuItem {
        let hostingView = NSHostingView(rootView: MenuContentView(viewModel: viewModel))
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 0)
        // Let the hosting view track its SwiftUI content's intrinsic size, so
        // the menu item grows/shrinks as the dashboard's content changes
        // (top-apps list, onboarding panel) instead of being pinned to a
        // one-shot `fittingSize` measured before that content settles.
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize]

        let menuItem = NSMenuItem()
        menuItem.view = hostingView
        return menuItem
    }

    /// Builds the Tracking Engine and its OS-backed signal sources and
    /// starts the automatic tracking pipeline described in
    /// `documentation/architecture-desktop.md` §Tracking Pipeline. If the
    /// local store fails to open, tracking simply does not start this
    /// launch rather than crashing the menu-bar shell.
    ///
    /// - Returns: The started engine and its backing store, for the
    ///   menu-bar dashboard to read live state and today's activity from, or
    ///   `nil` if the store failed to open.
    private func startTracking() -> (engine: TrackingEngine, store: LocalStore)? {
        guard let store = try? DatabaseManager.makeLocalStore() else {
            assertionFailure("Failed to open the local store; tracking will not start.")
            return nil
        }

        let engine = TrackingEngine(store: store)
        let coordinator = TrackingCoordinator(
            engine: engine,
            frontmostAppSource: NSWorkspaceFrontmostAppSource(),
            windowTitleSource: AccessibilityWindowTitleSource(),
            idleTimeSource: CGEventIdleTimeSource(),
            systemStateSource: SystemStateNotificationSource(),
            permissionSource: AXPermissionSource()
        )
        coordinator.start()

        trackingEngine = engine
        trackingCoordinator = coordinator
        return (engine, store)
    }

    /// Wires up the auth session and background push/pull sync loop
    /// (RIZ-41) against `store`: a `RemoteAuthAPIClient`/`RemoteSyncAPIClient`
    /// pair over `URLSession`, tokens split between in-memory (access) and
    /// Keychain (refresh + device id) per `documentation/security.md`, and a
    /// `SyncCoordinator` flushing every 60 seconds per
    /// `documentation/architecture-desktop.md` §Offline-First Store & Sync
    /// Loop.
    private func startSync(store: LocalStore) -> (authSession: AuthSessionViewModel, syncStatus: SyncStatusViewModel) {
        let transport = URLSessionHTTPTransport()
        let baseURLProvider = UserDefaultsBaseURLProvider()
        let authAPI = RemoteAuthAPIClient(transport: transport, baseURLProvider: baseURLProvider)
        let syncAPI = RemoteSyncAPIClient(transport: transport, baseURLProvider: baseURLProvider)
        let tokenStorage = KeychainAuthTokenStorage()

        let tokenManager = AuthTokenManager(api: authAPI, storage: tokenStorage)
        let authorizingSyncAPI = AuthorizingSyncAPIClient(inner: syncAPI, tokenManager: tokenManager)

        let engine = SyncEngine(
            localStore: store,
            syncAPI: authorizingSyncAPI,
            cursorStore: UserDefaultsSyncCursorStore(),
            tokenManager: tokenManager
        )
        let statusViewModel = SyncStatusViewModel()
        let coordinator = SyncCoordinator(engine: engine, statusViewModel: statusViewModel)
        syncCoordinator = coordinator
        Task { await coordinator.start() }

        return (AuthSessionViewModel(tokenManager: tokenManager), statusViewModel)
    }

    // MARK: - NSMenuDelegate

    /// Refreshes today's stats immediately and starts the periodic refresh
    /// loop while the menu is open, per the requirement that the dashboard
    /// stays current for as long as it's visible.
    func menuWillOpen(_ menu: NSMenu) {
        guard let menuContentViewModel else {
            return
        }
        menuContentViewModel.startAutoRefresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuContentViewModel?.stopAutoRefresh()
    }
}
