import SwiftUI

/// App entry point. RizeClone is a menu-bar-only app (`LSUIElement: true`), so
/// the SwiftUI `App` body declares no visible windows — the menu-bar shell is
/// built with AppKit's `NSStatusItem` in `AppDelegate`, not `MenuBarExtra`.
@main
struct RizeDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
