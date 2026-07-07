@testable import RizeDesktop
import XCTest

/// Exercises `TrackingDisplayState`'s lifecycle-state mapping and menu
/// status labels, per
/// `documentation/architecture-desktop.md` §Component Diagram.
final class TrackingDisplayStateTests: XCTestCase {
    func testIsPausedTakesPriorityOverLifecycleState() {
        let state = TrackingDisplayState(lifecycleState: .active, isPaused: true)

        XCTAssertEqual(state, .paused)
    }

    func testActiveLifecycleMapsToTracking() {
        let state = TrackingDisplayState(lifecycleState: .active, isPaused: false)

        XCTAssertEqual(state, .tracking)
    }

    func testIdleLifecycleMapsToIdle() {
        let state = TrackingDisplayState(lifecycleState: .idle, isPaused: false)

        XCTAssertEqual(state, .idle)
    }

    func testLockedLifecycleMapsToLocked() {
        let state = TrackingDisplayState(lifecycleState: .locked, isPaused: false)

        XCTAssertEqual(state, .locked)
    }

    func testSleepingLifecycleMapsToSleeping() {
        let state = TrackingDisplayState(lifecycleState: .sleeping, isPaused: false)

        XCTAssertEqual(state, .sleeping)
    }

    func testLabelsForEveryDisplayState() {
        XCTAssertEqual(TrackingDisplayState.tracking.label, "Tracking")
        XCTAssertEqual(TrackingDisplayState.idle.label, "Idle")
        XCTAssertEqual(TrackingDisplayState.locked.label, "Locked")
        XCTAssertEqual(TrackingDisplayState.sleeping.label, "Sleeping")
        XCTAssertEqual(TrackingDisplayState.paused.label, "Paused")
    }
}
