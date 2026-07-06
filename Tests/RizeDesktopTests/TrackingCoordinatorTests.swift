@testable import RizeDesktop
import XCTest

/// Exercises `TrackingCoordinator`'s wiring of the OS signal-source
/// protocols to a real `TrackingEngine` (backed by an in-memory
/// `LocalStore` fake) — the coordinator itself has no logic beyond this
/// plumbing, per `documentation/architecture-desktop.md` §Tracking
/// Pipeline. Every wait is bounded, either a small fixed delay (letting the
/// coordinator's background consumer tasks pick up a just-yielded signal)
/// or a `pollUntil` with an explicit timeout.
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

    func testStartWiresFrontmostAppSignalsToTheEngineAndProducesASegment() async throws {
        let frontmostApp = ControllableStream<FrontmostAppSample>()
        let systemState = ControllableStream<SystemStateSignal>()
        let (coordinator, _) = makeCoordinator(frontmostApp: frontmostApp, systemState: systemState)

        coordinator.start()
        frontmostApp.continuation.yield(FrontmostAppSample(bundleID: "com.acme.Editor"))
        // Bounded delay for the coordinator's background consumer task to
        // pick up the just-yielded sample before the segment is closed.
        try await Task.sleep(for: .milliseconds(100))

        clock.advance(by: 10)
        frontmostApp.continuation.yield(FrontmostAppSample(bundleID: "com.acme.Other"))

        try await pollUntil(timeout: 5) {
            await self.store.writtenEvents.isEmpty == false
        }
        coordinator.stop()

        let events = await store.writtenEvents
        XCTAssertEqual(events.first?.appBundleID, "com.acme.Editor")
    }

    func testStartWiresSystemStateSignalsToTheEngine() async throws {
        let frontmostApp = ControllableStream<FrontmostAppSample>()
        let systemState = ControllableStream<SystemStateSignal>()
        let (coordinator, engine) = makeCoordinator(frontmostApp: frontmostApp, systemState: systemState)

        coordinator.start()
        systemState.continuation.yield(.screenLocked)

        try await pollUntil(timeout: 5) {
            await engine.state == .locked
        }
        coordinator.stop()

        let finalState = await engine.state
        XCTAssertEqual(finalState, .locked)
    }

    func testStartTwiceRestartsThePollingLoopRatherThanDoublingIt() async throws {
        let frontmostApp = ControllableStream<FrontmostAppSample>()
        let systemState = ControllableStream<SystemStateSignal>()
        let (coordinator, engine) = makeCoordinator(
            frontmostApp: frontmostApp,
            systemState: systemState,
            idleSeconds: 301
        )

        coordinator.start()
        coordinator.start()

        try await pollUntil(timeout: 5) {
            await engine.state == .idle
        }
        coordinator.stop()

        let finalState = await engine.state
        XCTAssertEqual(finalState, .idle)
    }

    /// Bounded poll: retries `condition` every 10ms up to `timeout` seconds,
    /// failing the test (rather than hanging) if it never becomes true.
    private func pollUntil(
        timeout: TimeInterval,
        condition: () async throws -> Bool
    ) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition was not met within \(timeout)s")
    }
}
