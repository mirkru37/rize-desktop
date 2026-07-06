import AppKit
import SwiftUI

/// Owns the `NSStatusItem` menu-bar shell. `MenuBarExtra` is intentionally not
/// used here — see `documentation/system-overview.md` for the rationale
/// (AppKit's `NSStatusItem` gives full control over the menu-bar item).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var trackingEngine: TrackingEngine?
    private var trackingCoordinator: TrackingCoordinator?
    private var menuContentViewModel: MenuContentViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let tracking = startTracking()
        configureStatusItem(tracking: tracking)
    }

    /// Builds the menu-bar dashboard described in
    /// `documentation/architecture-desktop.md` §Component Diagram: a
    /// SwiftUI `MenuContentView` hosted inside the status item's menu,
    /// followed by a Quit item. `tracking` is `nil` if the local store
    /// failed to open (see `startTracking()`) — the dashboard is simply
    /// omitted in that case rather than crashing the menu-bar shell.
    private func configureStatusItem(tracking: (engine: TrackingEngine, store: LocalStore)?) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "RizeClone"
        )

        let menu = NSMenu()
        menu.delegate = self

        if let tracking {
            let viewModel = MenuContentViewModel(store: tracking.store, engine: tracking.engine)
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
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: hostingView.fittingSize.height)

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
