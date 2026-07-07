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
    func currentWindowTitle() async -> WindowTitleReading {
        guard AXIsProcessTrusted() else {
            return await cgWindowListFallback()
        }
        guard let title = await axFocusedWindowTitle() else {
            return await cgWindowListFallback()
        }
        return WindowTitleReading(title: title, path: .accessibility)
    }

    /// `NSWorkspace.shared.frontmostApplication` is main-thread-affined;
    /// this poller runs off the main thread, so the read is hopped over.
    @MainActor
    private func frontmostApplication() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    private func axFocusedWindowTitle() async -> String? {
        guard let frontApp = await frontmostApplication() else {
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

    private func cgWindowListFallback() async -> WindowTitleReading {
        guard let frontApp = await frontmostApplication() else {
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
///
/// The two centers are injectable (defaulting to the real
/// `DistributedNotificationCenter`/`NSWorkspace` centers used in
/// production) purely as a RIZ-67 testability seam: tests substitute plain
/// `NotificationCenter()` instances so screen-lock/unlock coverage doesn't
/// depend on the real distributed-notification daemon, which can be
/// unreliable/sandboxed on a CI runner. Only the base `NotificationCenter`
/// API (`addObserver`/`removeObserver`) is used, so a plain center is a
/// drop-in substitute for `DistributedNotificationCenter` here.
final class SystemStateNotificationSource: SystemStateSignalSource {
    private let distributedCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter

    init(
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.distributedCenter = distributedCenter
        self.workspaceCenter = workspaceCenter
    }

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
        let lock: NSObjectProtocol
        let unlock: NSObjectProtocol
        let sleep: NSObjectProtocol
        let wake: NSObjectProtocol
    }

    private func registerObservers(yielding yield: @escaping (SystemStateSignal) -> Void) -> RegisteredObservers {
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

        return RegisteredObservers(lock: lock, unlock: unlock, sleep: sleep, wake: wake)
    }

    private func removeObservers(_ observers: RegisteredObservers) {
        distributedCenter.removeObserver(observers.lock)
        distributedCenter.removeObserver(observers.unlock)
        workspaceCenter.removeObserver(observers.sleep)
        workspaceCenter.removeObserver(observers.wake)
    }
}

/// `AXIsProcessTrusted()`, per `documentation/architecture-desktop.md`
/// §Permissions & Entitlements.
final class AXPermissionSource: AccessibilityPermissionSource {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }
}
