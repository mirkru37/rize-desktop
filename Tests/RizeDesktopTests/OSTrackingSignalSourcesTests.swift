import AppKit
import ApplicationServices
@testable import RizeDesktop
import XCTest

/// Thread-safe sink for signals collected off a `Task` consuming an
/// `AsyncStream` — the `OSTrackingSignalSourcesTests` suite needs this
/// because the real `NotificationCenter` observer callbacks can run on
/// threads other than the test method's.
private actor SignalSink<Signal: Sendable> {
    private(set) var received: [Signal] = []

    func record(_ signal: Signal) {
        received.append(signal)
    }
}

/// Exercises the real, OS-backed signal sources against real
/// `NotificationCenter` instances — no fakes, since these types exist
/// specifically to wrap those real APIs — per
/// `documentation/architecture-desktop.md` §Tracking Pipeline.
///
/// Every wait is bounded via `fulfillment(of:timeout:)`, per the RIZ-67
/// brief's "no unbounded waits" rule. Every stream is constructed (`let
/// stream = source.events()`) *before* the consumer `Task` is created and
/// *before* anything is posted: `AsyncStream`'s `build` closure — which is
/// where these sources register their observers — runs synchronously the
/// moment `events()` is called, so hoisting that call out of the `Task`
/// guarantees registration happens-before the first post, regardless of
/// when the `Task` itself gets scheduled to run. Posting before that
/// registration is exactly the subscription race that made an earlier
/// version of this suite flaky.
final class OSTrackingSignalSourcesTests: XCTestCase {
    // MARK: - NSWorkspaceFrontmostAppSource

    func testEventsSeedsCurrentFrontmostAppAndYieldsOnActivation() async {
        let source = NSWorkspaceFrontmostAppSource()
        let stream = source.events()
        let sink = SignalSink<FrontmostAppSample>()
        let activatedExpectation = expectation(description: "activation sample received")
        let activatedApp = NSRunningApplication.current

        let consumerTask = Task {
            for await sample in stream {
                await sink.record(sample)
                let receivedCount = await sink.received.count
                if receivedCount == 2 { activatedExpectation.fulfill() }
            }
        }

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

    func testEventsYieldsANilBundleIDWhenActivationNotificationCarriesNoApp() async {
        let source = NSWorkspaceFrontmostAppSource()
        let stream = source.events()
        let sink = SignalSink<FrontmostAppSample>()
        let noAppExpectation = expectation(description: "sample with no app received")

        let consumerTask = Task {
            for await sample in stream {
                await sink.record(sample)
                let receivedCount = await sink.received.count
                if receivedCount == 2 { noAppExpectation.fulfill() }
            }
        }

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
        // Plain, test-local `NotificationCenter` instances injected in
        // place of the real `DistributedNotificationCenter`/`NSWorkspace`
        // centers: same in-process, synchronous (`queue: nil`) delivery
        // semantics, without depending on the real distributed-notification
        // daemon, which can be unreliable/sandboxed on a CI runner.
        let distributedCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let source = SystemStateNotificationSource(
            distributedCenter: distributedCenter,
            workspaceCenter: workspaceCenter
        )
        let stream = source.events()
        let sink = SignalSink<SystemStateSignal>()
        let lockedExpectation = expectation(description: "screenLocked received")
        let unlockedExpectation = expectation(description: "screenUnlocked received")

        let consumerTask = Task {
            for await signal in stream {
                await sink.record(signal)
                if signal == .screenLocked { lockedExpectation.fulfill() }
                if signal == .screenUnlocked { unlockedExpectation.fulfill() }
            }
        }

        distributedCenter.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        await fulfillment(of: [lockedExpectation], timeout: 5)

        distributedCenter.post(name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        await fulfillment(of: [unlockedExpectation], timeout: 5)
        consumerTask.cancel()

        let received = await sink.received
        XCTAssertEqual(received, [.screenLocked, .screenUnlocked])
    }

    func testEventsYieldsOnWillSleepAndDidWakeNotifications() async {
        let distributedCenter = NotificationCenter()
        let workspaceCenter = NotificationCenter()
        let source = SystemStateNotificationSource(
            distributedCenter: distributedCenter,
            workspaceCenter: workspaceCenter
        )
        let stream = source.events()
        let sink = SignalSink<SystemStateSignal>()
        let sleepExpectation = expectation(description: "willSleep received")
        let wakeExpectation = expectation(description: "didWake received")

        let consumerTask = Task {
            for await signal in stream {
                await sink.record(signal)
                if signal == .willSleep { sleepExpectation.fulfill() }
                if signal == .didWake { wakeExpectation.fulfill() }
            }
        }

        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await fulfillment(of: [sleepExpectation], timeout: 5)

        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
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
