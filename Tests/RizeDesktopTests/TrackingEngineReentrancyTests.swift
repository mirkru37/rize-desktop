@testable import RizeDesktop
import XCTest

/// Regression coverage for RIZ-39 review finding H1/M5 (actor reentrancy
/// during segment persistence). Split out of `TrackingEngineTests` — which
/// was already at the `file_length`/`type_body_length` limits — rather than
/// growing that file further; see it for the rest of the state
/// machine/segmentation coverage.
final class TrackingEngineReentrancyTests: XCTestCase {
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

    /// A `LocalStore` whose `writeEvent` suspends until the test explicitly
    /// opens the gate, used to reproduce actor reentrancy during
    /// persistence (RIZ-39 review, finding H1/M5). Every `writeEvent` call
    /// suspends independently until the gate is opened — each suspension is
    /// its own continuation appended to `gateWaiters`, so multiple
    /// concurrent writes (e.g. the Terminal close and the reentrant Safari
    /// close) are never lost or overwritten — after which future calls pass
    /// straight through.
    ///
    /// `onEntry` fires every time a `writeEvent` call reaches the gate,
    /// letting the test drive an `XCTestExpectation` per entry instead of a
    /// bespoke continuation-based "has entered" signal — that first version
    /// deadlocked the test itself (see the test's doc comment), and an
    /// expectation-based, timeout-bounded wait can't hang the suite even if
    /// a future change to this fake breaks the assumed entry count.
    private actor SuspendableLocalStore: LocalStore {
        private(set) var writtenEvents: [ActivityEvent] = []
        private var isGateOpen = false
        private var gateWaiters: [CheckedContinuation<Void, Never>] = []
        private var onEntry: (@Sendable (Int) -> Void)?
        private var entryCount = 0

        func writeEvent(_ event: ActivityEvent) async throws {
            entryCount += 1
            onEntry?(entryCount)
            if !isGateOpen {
                await withCheckedContinuation { continuation in
                    gateWaiters.append(continuation)
                }
            }
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

        /// Registers a callback invoked (with the running entry count)
        /// every time a `writeEvent` call reaches the gate.
        func setOnEntry(_ handler: @escaping @Sendable (Int) -> Void) {
            onEntry = handler
        }

        /// Releases every `writeEvent` call currently suspended, and lets
        /// all future calls proceed without suspending.
        func openGate() {
            isGateOpen = true
            let waiters = gateWaiters
            gateWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private var clock: MutableClock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        clock = MutableClock(date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    override func tearDown() {
        clock = nil
        super.tearDown()
    }

    /// Regression test for RIZ-39 review finding H1: a competing signal
    /// arriving while a previous segment's write is still suspended must
    /// not have its own segment overwritten once that write resumes.
    ///
    /// The Mail switch below closes the Safari segment, which itself
    /// persists through the same gated store — so it must run as its own
    /// `Task` and be waited on via a bounded `XCTestExpectation`, exactly
    /// like the Terminal->Safari switch. An earlier version of this test
    /// awaited the Mail switch directly on the test's own task before
    /// opening the gate; because that switch's own persistence suspends on
    /// the same gate, the test deadlocked itself and hung CI's `Test` step
    /// for the full timeout (RIZ-39 review follow-up). Every wait here is
    /// timeout-bounded so a wrong assumption about entry counts fails fast
    /// instead of hanging again.
    func testReentrantAppSwitchDuringPersistenceDoesNotClobberSegments() async {
        let suspendableStore = SuspendableLocalStore()
        let engine = TrackingEngine(
            store: suspendableStore,
            clock: clock,
            idleThreshold: 300,
            minimumEventDuration: 5
        )

        let (firstSwitch, secondSwitch) = await triggerReentrantSwitches(engine: engine, store: suspendableStore)
        await firstSwitch.value
        await secondSwitch.value

        // A further switch proves the engine's current segment reflects
        // Mail, not stale data from the suspended Safari close.
        clock.advance(by: 20)
        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Finder")

        let events = await suspendableStore.writtenEvents
        assertReentrantSwitchEvents(events)
    }

    /// Starts closing the Terminal segment (suspended on `store`'s gate),
    /// then delivers a competing Mail switch while that write is still in
    /// flight — the Mail switch closes the Safari segment opened by the
    /// first switch, so it also persists through the gated store and must
    /// run concurrently rather than being awaited inline. Returns both
    /// tasks, with the gate already opened, for the caller to await.
    private func triggerReentrantSwitches(
        engine: TrackingEngine,
        store: SuspendableLocalStore
    ) async -> (Task<Void, Never>, Task<Void, Never>) {
        let terminalWriteEntered = expectation(description: "Terminal write entered the gate")
        let safariWriteEntered = expectation(description: "Safari write entered the gate")
        await store.setOnEntry { count in
            if count == 1 { terminalWriteEntered.fulfill() }
            if count == 2 { safariWriteEntered.fulfill() }
        }

        await engine.handleFrontmostAppChanged(bundleID: "com.apple.Terminal")
        clock.advance(by: 10)

        let firstSwitch = Task {
            await engine.handleFrontmostAppChanged(bundleID: "com.apple.Safari")
        }
        await fulfillment(of: [terminalWriteEntered], timeout: 5)

        clock.advance(by: 8)
        let secondSwitch = Task {
            await engine.handleFrontmostAppChanged(bundleID: "com.apple.Mail")
        }
        await fulfillment(of: [safariWriteEntered], timeout: 5)

        await store.openGate()
        return (firstSwitch, secondSwitch)
    }

    private func assertReentrantSwitchEvents(_ events: [ActivityEvent]) {
        XCTAssertEqual(
            Set(events.map(\.appBundleID)),
            Set(["com.apple.Terminal", "com.apple.Safari", "com.apple.Mail"])
        )
        for event in events {
            XCTAssertGreaterThan(event.endedAt, event.startedAt)
        }

        guard let terminalEvent = events.first(where: { $0.appBundleID == "com.apple.Terminal" }) else {
            return XCTFail("missing Terminal event")
        }
        guard let safariEvent = events.first(where: { $0.appBundleID == "com.apple.Safari" }) else {
            return XCTFail("missing Safari event")
        }
        guard let mailEvent = events.first(where: { $0.appBundleID == "com.apple.Mail" }) else {
            return XCTFail("missing Mail event")
        }

        XCTAssertEqual(terminalEvent.endedAt.timeIntervalSince(terminalEvent.startedAt), 10, accuracy: 0.001)
        XCTAssertEqual(safariEvent.endedAt.timeIntervalSince(safariEvent.startedAt), 8, accuracy: 0.001)
        XCTAssertEqual(mailEvent.endedAt.timeIntervalSince(mailEvent.startedAt), 20, accuracy: 0.001)

        // Segments are contiguous, i.e. monotonic and correctly attributed.
        XCTAssertEqual(safariEvent.startedAt, terminalEvent.endedAt)
        XCTAssertEqual(mailEvent.startedAt, safariEvent.endedAt)
    }
}
