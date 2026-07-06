@testable import RizeDesktop
import XCTest

/// Exercises `TrackingEngine.pause()`/`resume()`, added for the menu-bar
/// dashboard's pause control (`documentation/architecture-desktop.md`
/// §Component Diagram). Kept separate from `TrackingEngineTests` to avoid
/// growing that file further; see it for the state machine/segmentation
/// coverage this reuses the same testing approach as (simulated signals fed
/// directly through the engine's `handle*`/control methods, no sleeps).
final class TrackingEnginePauseTests: XCTestCase {
    private final class MutableClock: Clock, @unchecked Sendable {
        private(set) var date: Date
        init(date: Date) {
            self.date = date
        }

        func now() -> Date {
            date
        }

        func advance(by seconds: TimeInterval) {
            date = date.addingTimeInterval(seconds)
        }
    }

    private actor FakeLocalStore: LocalStore {
        private(set) var writtenEvents: [ActivityEvent] = []

        func writeEvent(_ event: ActivityEvent) async throws {
            writtenEvents.append(event)
        }

        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}
        func tombstoneSession(id: UUID, at date: Date) async throws {}
        func fetchTodayActivity() async throws -> [ActivityEvent] {
            writtenEvents
        }

        func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
            []
        }

        func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {}
    }

    private var clock: MutableClock!
    private var store: FakeLocalStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        clock = MutableClock(date: Date(timeIntervalSince1970: 1_800_000_000))
        store = FakeLocalStore()
    }

    override func tearDown() {
        clock = nil
        store = nil
        super.tearDown()
    }

    private func makeEngine() -> TrackingEngine {
        TrackingEngine(store: store, clock: clock, idleThreshold: 300, minimumEventDuration: 5)
    }

    func testPauseClosesOpenSegmentAndSuppressesFurtherEventsUntilResumed() async {
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Editor")
        clock.advance(by: 10)
        await engine.pause()
        clock.advance(by: 20)
        // App switches while paused must not produce further segments.
        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Other")

        let events = await store.writtenEvents
        XCTAssertEqual(events.map(\.type), [.appActive])
        XCTAssertEqual(events[0].endedAt.timeIntervalSince(events[0].startedAt), 10, accuracy: 0.001)
        let paused = await engine.isPaused
        XCTAssertTrue(paused)
    }

    func testResumeAfterPauseResumesTrackingTheCurrentFrontmostApp() async {
        let engine = makeEngine()

        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Editor")
        clock.advance(by: 10)
        await engine.pause()
        clock.advance(by: 30)
        await engine.resume()
        clock.advance(by: 15)
        await engine.handleFrontmostAppChanged(bundleID: "com.acme.Other")

        let events = await store.writtenEvents
        // The paused gap itself is never persisted (`SegmentKind.paused`
        // maps to no event), only the two Editor segments either side of it.
        XCTAssertEqual(events.map(\.type), [.appActive, .appActive])
        XCTAssertEqual(events.map(\.appBundleID), ["com.acme.Editor", "com.acme.Editor"])
        XCTAssertEqual(events[1].endedAt.timeIntervalSince(events[1].startedAt), 15, accuracy: 0.001)
        let paused = await engine.isPaused
        XCTAssertFalse(paused)
    }

    func testPausingWithNoOpenSegmentProducesNoEvent() async {
        let engine = makeEngine()

        await engine.pause()

        let events = await store.writtenEvents
        XCTAssertTrue(events.isEmpty)
    }

    func testPermissionStateIsUnaffectedByPause() async {
        let engine = makeEngine()

        await engine.handleAccessibilityPermissionChanged(isTrusted: false)
        await engine.pause()

        let permissionState = await engine.permissionState
        XCTAssertEqual(permissionState, .denied)
    }
}
