import AppKit
import ApplicationServices
@testable import RizeDesktop
import XCTest

/// Thread-safe sink for signals collected off a `Task` consuming an
/// `AsyncStream` — the `OSTrackingSignalSourcesTests` suite needs this
/// because the real `NotificationCenter`/`DistributedNotificationCenter`
/// observer callbacks can run on threads other than the test method's.
private actor SignalSink<Signal: Sendable> {
    private(set) var received: [Signal] = []

    func record(_ signal: Signal) {
        received.append(signal)
    }
}

/// Exercises the real, OS-backed signal sources against the actual
/// `NotificationCenter`/`DistributedNotificationCenter` instances they
/// observe — no fakes, since these types exist specifically to wrap those
/// real APIs — per `documentation/architecture-desktop.md` §Tracking
/// Pipeline. Every wait is bounded via `fulfillment(of:timeout:)`, per the
/// RIZ-67 brief's "no unbounded waits" rule: if a notification somehow
/// never arrives in a given CI sandbox, the test fails fast at the timeout
/// instead of hanging.
final class OSTrackingSignalSourcesTests: XCTestCase {
    // MARK: - NSWorkspaceFrontmostAppSource

    func testEventsSeedsCurrentFrontmostAppAndYieldsOnActivation() async throws {
        let source = NSWorkspaceFrontmostAppSource()
        let sink = SignalSink<FrontmostAppSample>()
        let activatedExpectation = expectation(description: "activation sample received")
        let activatedApp = NSRunningApplication.current

        let consumerTask = Task {
            for await sample in source.events() {
                await sink.record(sample)
                let receivedCount = await sink.received.count
                if receivedCount == 2 { activatedExpectation.fulfill() }
            }
        }
        // Give the stream's seed value a moment to land before activating,
        // so the two samples arrive in a known order.
        try await Task.sleep(for: .milliseconds(50))

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: activatedApp]
        )

        await fulfillment(of: [activatedExpectation], timeout: 5)
        consumerTask.cancel()

        let received = await sink.received
        XCTAssertEqual(received.first?.bundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        XCTAssertEqual(received.last?.bundleID, activatedApp.bundleIdentifier)
    }

    func testEventsYieldsANilBundleIDWhenActivationNotificationCarriesNoApp() async throws {
        let source = NSWorkspaceFrontmostAppSource()
        let sink = SignalSink<FrontmostAppSample>()
        let noAppExpectation = expectation(description: "sample with no app received")

        let consumerTask = Task {
            for await sample in source.events() {
                await sink.record(sample)
                let receivedCount = await sink.received.count
                if receivedCount == 2 { noAppExpectation.fulfill() }
            }
        }
        try await Task.sleep(for: .milliseconds(50))

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            userInfo: [:]
        )

        await fulfillment(of: [noAppExpectation], timeout: 5)
        consumerTask.cancel()

        let received = await sink.received
        XCTAssertNil(received.last?.bundleID)
    }

    // MARK: - SystemStateNotificationSource

    func testEventsYieldsOnScreenLockAndUnlockNotifications() async {
        let source = SystemStateNotificationSource()
        let sink = SignalSink<SystemStateSignal>()
        let lockedExpectation = expectation(description: "screenLocked received")
        let unlockedExpectation = expectation(description: "screenUnlocked received")

        let consumerTask = Task {
            for await signal in source.events() {
                await sink.record(signal)
                if signal == .screenLocked { lockedExpectation.fulfill() }
                if signal == .screenUnlocked { unlockedExpectation.fulfill() }
            }
        }

        // `deliverImmediately: true` avoids relying on the distributed
        // notification daemon's default suspension/coalescing behavior, so
        // the same-process observer above receives it promptly.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        await fulfillment(of: [lockedExpectation], timeout: 5)

        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        await fulfillment(of: [unlockedExpectation], timeout: 5)
        consumerTask.cancel()

        let received = await sink.received
        XCTAssertEqual(received, [.screenLocked, .screenUnlocked])
    }

    func testEventsYieldsOnWillSleepAndDidWakeNotifications() async {
        let source = SystemStateNotificationSource()
        let sink = SignalSink<SystemStateSignal>()
        let sleepExpectation = expectation(description: "willSleep received")
        let wakeExpectation = expectation(description: "didWake received")

        let consumerTask = Task {
            for await signal in source.events() {
                await sink.record(signal)
                if signal == .willSleep { sleepExpectation.fulfill() }
                if signal == .didWake { wakeExpectation.fulfill() }
            }
        }

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [sleepExpectation], timeout: 5)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [wakeExpectation], timeout: 5)
        consumerTask.cancel()

        let received = await sink.received
        XCTAssertEqual(received, [.willSleep, .didWake])
    }

    // MARK: - AXPermissionSource / CGEventIdleTimeSource

    func testAXPermissionSourceDelegatesToAXIsProcessTrusted() {
        let source = AXPermissionSource()

        // `AXPermissionSource` is a thin wrapper with no logic of its own;
        // this asserts it actually delegates rather than hardcoding a value.
        XCTAssertEqual(source.isTrusted(), AXIsProcessTrusted())
    }

    func testCGEventIdleTimeSourceReturnsANonNegativeInterval() {
        let source = CGEventIdleTimeSource()

        let seconds = source.secondsSinceLastEvent()

        XCTAssertGreaterThanOrEqual(seconds, 0)
    }
}
