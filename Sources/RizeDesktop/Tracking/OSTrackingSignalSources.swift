import AppKit
import ApplicationServices
import CoreGraphics

// Real, OS-backed signal sources for the Tracking Engine. Kept in their own
// file, separate from the engine and coordinator, because these are the
// only tracking components that need to import AppKit/Accessibility/
// CoreGraphics — everything else depends only on the protocols in
// `TrackingSignalSources.swift`.

/// `NSWorkspace.didActivateApplicationNotification`, per
/// `documentation/architecture-desktop.md` §Tracking Pipeline.
final class NSWorkspaceFrontmostAppSource: FrontmostAppSignalSource {
    func events() -> AsyncStream<FrontmostAppSample> {
        AsyncStream { continuation in
            // Seed with the currently-frontmost app; the activation
            // notification only fires on subsequent switches.
            let currentBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            continuation.yield(FrontmostAppSample(bundleID: currentBundleID))

            let center = NSWorkspace.shared.notificationCenter
            let observer = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                continuation.yield(FrontmostAppSample(bundleID: app?.bundleIdentifier))
            }
            continuation.onTermination = { _ in
                center.removeObserver(observer)
            }
        }
    }
}

/// Resolves the focused window's title via the Accessibility API, falling
/// back to `CGWindowList` (`kCGWindowName`) when Accessibility is
/// unavailable, per `documentation/architecture-desktop.md` §Tracking
/// Pipeline and §Permissions & Entitlements.
final class AccessibilityWindowTitleSource: WindowTitleSignalSource {
    func currentWindowTitle() -> WindowTitleReading {
        guard AXIsProcessTrusted() else {
            return cgWindowListFallback()
        }
        guard let title = axFocusedWindowTitle() else {
            return cgWindowListFallback()
        }
        return WindowTitleReading(title: title, path: .accessibility)
    }

    private func axFocusedWindowTitle() -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedWindowRef: AnyObject?
        let windowResult = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )
        guard windowResult == .success, let focusedWindowRef else {
            return nil
        }
        let focusedWindow = unsafeBitCast(focusedWindowRef, to: AXUIElement.self)

        var titleRef: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleRef)
        guard titleResult == .success else {
            return nil
        }
        return titleRef as? String
    }

    private func cgWindowListFallback() -> WindowTitleReading {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return WindowTitleReading(title: nil, path: .unavailable)
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return WindowTitleReading(title: nil, path: .unavailable)
        }

        let targetPID = frontApp.processIdentifier
        let ownedWindow = windowList.first { info in
            (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == targetPID
        }
        guard let title = ownedWindow?[kCGWindowName as String] as? String else {
            return WindowTitleReading(title: nil, path: .unavailable)
        }
        return WindowTitleReading(title: title, path: .cgWindowListFallback)
    }
}

/// `CGEventSource.secondsSinceLastEventType`, per
/// `documentation/architecture-desktop.md` §Tracking State Machine.
final class CGEventIdleTimeSource: IdleTimeSignalSource {
    func secondsSinceLastEvent() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null)
    }
}

/// The distributed screen-lock notification and `NSWorkspace` sleep/wake
/// notifications, per `documentation/architecture-desktop.md` §Tracking
/// State Machine.
final class SystemStateNotificationSource: SystemStateSignalSource {
    func events() -> AsyncStream<SystemStateSignal> {
        AsyncStream<SystemStateSignal> { (continuation: AsyncStream<SystemStateSignal>.Continuation) in
            let observers = self.registerObservers(yielding: { signal in
                continuation.yield(signal)
            })
            continuation.onTermination = { (_: AsyncStream<SystemStateSignal>.Continuation.Termination) in
                self.removeObservers(observers)
            }
        }
    }

    private struct RegisteredObservers {
        let distributedCenter: DistributedNotificationCenter
        let workspaceCenter: NotificationCenter
        let lock: NSObjectProtocol
        let unlock: NSObjectProtocol
        let sleep: NSObjectProtocol
        let wake: NSObjectProtocol
    }

    private func registerObservers(yielding yield: @escaping (SystemStateSignal) -> Void) -> RegisteredObservers {
        let distributedCenter = DistributedNotificationCenter.default()
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        let lock = distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: nil
        ) { _ in yield(.screenLocked) }
        let unlock = distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: nil
        ) { _ in yield(.screenUnlocked) }
        let sleep = workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: nil
        ) { _ in yield(.willSleep) }
        let wake = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in yield(.didWake) }

        return RegisteredObservers(
            distributedCenter: distributedCenter,
            workspaceCenter: workspaceCenter,
            lock: lock,
            unlock: unlock,
            sleep: sleep,
            wake: wake
        )
    }

    private func removeObservers(_ observers: RegisteredObservers) {
        observers.distributedCenter.removeObserver(observers.lock)
        observers.distributedCenter.removeObserver(observers.unlock)
        observers.workspaceCenter.removeObserver(observers.sleep)
        observers.workspaceCenter.removeObserver(observers.wake)
    }
}

/// `AXIsProcessTrusted()`, per `documentation/architecture-desktop.md`
/// §Permissions & Entitlements.
final class AXPermissionSource: AccessibilityPermissionSource {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
