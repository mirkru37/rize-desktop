import AppKit

/// Owns the `NSStatusItem` menu-bar shell. `MenuBarExtra` is intentionally not
/// used here — see `documentation/system-overview.md` for the rationale
/// (AppKit's `NSStatusItem` gives full control over the menu-bar item).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}
