@testable import RizeDesktop
import XCTest

/// Exercises `TrackingCoordinator`'s wiring of the OS signal-source
/// protocols to a real `TrackingEngine` (backed by an in-memory
/// `LocalStore` fake) — the coordinator itself has no logic beyond this
/// plumbing, per `documentation/architecture-desktop.md` §Tracking
/// Pipeline. Every wait is a deterministic, timeout-bounded rendezvous on
/// `TrackingCoordinator.signalAppliedProbe` (a test-only hook fired once a
/// signal has been fully applied to the engine) rather than a wall-clock
/// delay or a fixed-interval polling loop — see `expectNextApplied` below.
final class TrackingCoordinatorTests: XCTestCase {
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

    /// A `FrontmostAppSignalSource`/`SystemStateSignalSource` double whose
    /// stream the test controls directly via `continuation`.
    private final class ControllableStream<Signal: Sendable>: Sendable {
        let stream: AsyncStream<Signal>
        let continuation: AsyncStream<Signal>.Continuation

        init() {
            var continuation: AsyncStream<Signal>.Continuation!
            stream = AsyncStream { continuation = $0 }
            self.continuation = continuation
        }
    }

    private struct StubFrontmostAppSource: FrontmostAppSignalSource {
        let controllable: ControllableStream<FrontmostAppSample>
        func events() -> AsyncStream<FrontmostAppSample> {
            controllable.stream
        }
    }

    private struct StubSystemStateSource: SystemStateSignalSource {
        let controllable: ControllableStream<SystemStateSignal>
        func events() -> AsyncStream<SystemStateSignal> {
            controllable.stream
        }
    }

    private struct StubWindowTitleSource: WindowTitleSignalSource {
        let reading: WindowTitleReading
        func currentWindowTitle() async -> WindowTitleReading {
            reading
        }
    }

    private struct StubIdleTimeSource: IdleTimeSignalSource {
        let seconds: TimeInterval
        func secondsSinceLastEvent() -> TimeInterval {
            seconds
        }
    }

    private struct StubPermissionSource: AccessibilityPermissionSource {
        let trusted: Bool
        func isTrusted() -> Bool {
            trusted
        }
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

    private func makeCoordinator(
        frontmostApp: ControllableStream<FrontmostAppSample>,
        systemState: ControllableStream<SystemStateSignal>,
        idleSeconds: TimeInterval = 0,
        trusted: Bool = true
    ) -> (TrackingCoordinator, TrackingEngine) {
        let engine = TrackingEngine(store: store, clock: clock)
        let coordinator = TrackingCoordinator(
            engine: engine,
            frontmostAppSource: StubFrontmostAppSource(controllable: frontmostApp),
            windowTitleSource: StubWindowTitleSource(reading: WindowTitleReading(title: nil, path: .unavailable)),
            idleTimeSource: StubIdleTimeSource(seconds: idleSeconds),
            systemStateSource: StubSystemStateSource(controllable: systemState),
            permissionSource: StubPermissionSource(trusted: trusted),
            pollingInterval: .milliseconds(20)
        )
        return (coordinator, engine)
    }

    /// Arms `coordinator.signalAppliedProbe` to fulfill `expectation` the
    /// next time `signal` is fully applied to the engine, then clears itself
    /// so a signal that keeps firing (e.g. the polling loop) can't
    /// over-fulfill it.
    private func expectNextApplied(
        _ signal: TrackingCoordinator.AppliedSignal,
        on coordinator: TrackingCoordinator,
        fulfilling expectation: XCTestExpectation
    ) {
        coordinator.signalAppliedProbe = { [weak coordinator] appliedSignal in
            guard appliedSignal == signal else { return }
            coordinator?.signalAppliedProbe = nil
            expectation.fulfill()
        }
    }

    func testStartWiresFrontmostAppSignalsToTheEngineAndProducesASegment() async {
        let frontmostApp = ControllableStream<FrontmostAppSample>()
        let systemState = ControllableStream<SystemStateSignal>()
        let (coordinator, _) = makeCoordinator(frontmostApp: frontmostApp, systemState: systemState)

        let editorApplied = expectation(description: "Editor frontmost signal applied to the engine")
        expectNextApplied(.frontmostApp, on: coordinator, fulfilling: editorApplied)

        coordinator.start()
        frontmostApp.continuation.yield(FrontmostAppSample(bundleID: "com.acme.Editor"))
        // Deterministic rendezvous: only advance the clock once "Editor" has
        // actually been applied to the engine, so its segment's `startedAt`
        // is guaranteed to precede the advance rather than racing it.
        await fulfillment(of: [editorApplied], timeout: 5)

        clock.advance(by: 10)

        let otherApplied = expectation(description: "Other frontmost signal applied (closes Editor's segment)")
        expectNextApplied(.frontmostApp, on: coordinator, fulfilling: otherApplied)
        frontmostApp.continuation.yield(FrontmostAppSample(bundleID: "com.acme.Other"))
        await fulfillment(of: [otherApplied], timeout: 5)
        coordinator.stop()

        let events = await store.writtenEvents
        XCTAssertEqual(events.first?.appBundleID, "com.acme.Editor")
    }

    func testStartWiresSystemStateSignalsToTheEngine() async {
        let frontmostApp = ControllableStream<FrontmostAppSample>()
        let systemState = ControllableStream<SystemStateSignal>()
        let (coordinator, engine) = makeCoordinator(frontmostApp: frontmostApp, systemState: systemState)

        let lockedApplied = expectation(description: "screenLocked signal applied to the engine")
        expectNextApplied(.systemState, on: coordinator, fulfilling: lockedApplied)

        coordinator.start()
        systemState.continuation.yield(.screenLocked)
        await fulfillment(of: [lockedApplied], timeout: 5)
        coordinator.stop()

        let finalState = await engine.state
        XCTAssertEqual(finalState, .locked)
    }

    func testStartTwiceRestartsThePollingLoopRatherThanDoublingIt() async {
        let frontmostApp = ControllableStream<FrontmostAppSample>()
        let systemState = ControllableStream<SystemStateSignal>()
        let (coordinator, engine) = makeCoordinator(
            frontmostApp: frontmostApp,
            systemState: systemState,
            idleSeconds: 301
        )

        let idleApplied = expectation(description: "a poll cycle applied the idle transition to the engine")
        expectNextApplied(.poll, on: coordinator, fulfilling: idleApplied)

        coordinator.start()
        coordinator.start()
        await fulfillment(of: [idleApplied], timeout: 5)
        coordinator.stop()

        let finalState = await engine.state
        XCTAssertEqual(finalState, .idle)
    }
}
