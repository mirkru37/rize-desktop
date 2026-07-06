import AppKit

/// Owns the `NSStatusItem` menu-bar shell. `MenuBarExtra` is intentionally not
/// used here — see `documentation/system-overview.md` for the rationale
/// (AppKit's `NSStatusItem` gives full control over the menu-bar item).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var trackingEngine: TrackingEngine?
    private var trackingCoordinator: TrackingCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        startTracking()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "clock",
            accessibilityDescription: "RizeClone"
        )

        let menu = NSMenu()

        let statusMenuItem = NSMenuItem(
            title: "Tracking: not yet implemented",
            action: nil,
            keyEquivalent: ""
        )
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        let quitMenuItem = NSMenuItem(
            title: "Quit RizeClone",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitMenuItem)

        item.menu = menu
        statusItem = item
    }

    /// Builds the Tracking Engine and its OS-backed signal sources and
    /// starts the automatic tracking pipeline described in
    /// `documentation/architecture-desktop.md` §Tracking Pipeline. If the
    /// local store fails to open, tracking simply does not start this
    /// launch rather than crashing the menu-bar shell.
    private func startTracking() {
        guard let store = try? DatabaseManager.makeLocalStore() else {
            assertionFailure("Failed to open the local store; tracking will not start.")
            return
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
    }
}
