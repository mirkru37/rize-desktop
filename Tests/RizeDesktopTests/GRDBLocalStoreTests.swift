import GRDB
@testable import RizeDesktop
import XCTest

final class GRDBLocalStoreTests: XCTestCase {
    /// A fixed, injectable clock so "today" boundaries and sync timestamps
    /// are deterministic instead of depending on the wall clock.
    private struct FixedClock: Clock {
        let date: Date
        func now() -> Date {
            date
        }
    }

    private var dbQueue: DatabaseQueue!
    private var calendar: Calendar!
    private var referenceNow: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbQueue = try DatabaseQueue()
        try DatabaseMigrations.makeMigrator().migrate(dbQueue)

        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        referenceNow = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12))
        )
    }

    override func tearDown() {
        dbQueue = nil
        calendar = nil
        referenceNow = nil
        super.tearDown()
    }

    private func makeStore() -> GRDBLocalStore {
        GRDBLocalStore(dbWriter: dbQueue, clock: FixedClock(date: referenceNow), calendar: calendar)
    }

    private func makeEvent(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        deleted: Bool = false,
        syncedAt: Date? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            eventID: id,
            startedAt: startedAt,
            endedAt: endedAt,
            type: .appActive,
            appBundleID: "com.apple.dt.Xcode",
            windowTitle: "Test.swift",
            deleted: deleted,
            insertedAt: startedAt,
            syncedAt: syncedAt
        )
    }

    // MARK: - Migrations

    func testMigratorAppliesCleanlyAndIsIdempotent() throws {
        let migrator = DatabaseMigrations.makeMigrator()
        // Re-applying against an already-migrated database is a no-op, not
        // an error.
        try migrator.migrate(dbQueue)

        let appliedCount = try dbQueue.read { db in
            try migrator.appliedMigrations(db).count
        }
        XCTAssertEqual(appliedCount, 2)
    }

    // MARK: - Round trips

    func testWriteEventRoundTrips() async throws {
        let store = makeStore()
        let started = referenceNow.addingTimeInterval(-60)
        let event = makeEvent(startedAt: started, endedAt: referenceNow)

        try await store.writeEvent(event)

        let fetched = try await store.fetchTodayActivity()
        XCTAssertEqual(fetched, [event])
    }

    func testUpsertSessionRoundTrips() async throws {
        let store = makeStore()
        let session = FocusSession(
            id: UUID(),
            kind: .focus,
            startedAt: referenceNow,
            status: .running,
            createdAt: referenceNow,
            updatedAt: referenceNow
        )

        try await store.upsertSession(session)

        let fetched = try await dbQueue.read { db in
            try FocusSession.fetchOne(db, key: session.id)
        }
        XCTAssertEqual(fetched, session)
    }

    func testUpsertSessionUpdatesExistingRowRatherThanDuplicating() async throws {
        let store = makeStore()
        let id = UUID()
        var session = FocusSession(
            id: id,
            kind: .focus,
            startedAt: referenceNow,
            status: .running,
            createdAt: referenceNow,
            updatedAt: referenceNow
        )
        try await store.upsertSession(session)

        session.status = .completed
        session.endedAt = referenceNow.addingTimeInterval(1500)
        session.updatedAt = referenceNow.addingTimeInterval(1500)
        try await store.upsertSession(session)

        let count = try await dbQueue.read { db in try FocusSession.fetchCount(db) }
        XCTAssertEqual(count, 1)

        let fetched = try await dbQueue.read { db in try FocusSession.fetchOne(db, key: id) }
        XCTAssertEqual(fetched?.status, .completed)
    }

    // MARK: - Today's activity

    func testFetchTodayActivityExcludesEventsFromOtherDays() async throws {
        let store = makeStore()
        let startOfToday = calendar.startOfDay(for: referenceNow)

        let todayEvent = makeEvent(
            startedAt: startOfToday.addingTimeInterval(60),
            endedAt: startOfToday.addingTimeInterval(120)
        )
        let yesterdayEvent = makeEvent(
            startedAt: startOfToday.addingTimeInterval(-3600),
            endedAt: startOfToday.addingTimeInterval(-3500)
        )
        let tomorrowEvent = makeEvent(
            startedAt: startOfToday.addingTimeInterval(90000),
            endedAt: startOfToday.addingTimeInterval(90060)
        )

        try await store.writeEvent(todayEvent)
        try await store.writeEvent(yesterdayEvent)
        try await store.writeEvent(tomorrowEvent)

        let fetched = try await store.fetchTodayActivity()
        XCTAssertEqual(fetched.map(\.eventID), [todayEvent.eventID])
    }

    func testFetchTodayActivityExcludesTombstonedEvents() async throws {
        let store = makeStore()
        let event = makeEvent(startedAt: referenceNow.addingTimeInterval(-60), endedAt: referenceNow)
        try await store.writeEvent(event)

        try await store.tombstoneEvent(id: event.eventID, at: referenceNow)

        let fetched = try await store.fetchTodayActivity()
        XCTAssertTrue(fetched.isEmpty)
    }

    // MARK: - Unsynced batch selection

    func testFetchUnsyncedEventsReturnsOnlyPendingRowsOldestFirst() async throws {
        let store = makeStore()
        let synced = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-300),
            endedAt: referenceNow.addingTimeInterval(-240),
            syncedAt: referenceNow
        )
        let pendingOlder = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-200),
            endedAt: referenceNow.addingTimeInterval(-180)
        )
        let pendingNewer = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-100),
            endedAt: referenceNow.addingTimeInterval(-80)
        )

        try await store.writeEvent(synced)
        try await store.writeEvent(pendingNewer)
        try await store.writeEvent(pendingOlder)

        let unsynced = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertEqual(unsynced.map(\.eventID), [pendingOlder.eventID, pendingNewer.eventID])
    }

    func testFetchUnsyncedEventsClampsLimitToProtocolMaximum() async throws {
        let store = makeStore()
        for offset in 0 ..< 10 {
            let event = makeEvent(
                startedAt: referenceNow.addingTimeInterval(TimeInterval(-offset - 1)),
                endedAt: referenceNow.addingTimeInterval(TimeInterval(-offset))
            )
            try await store.writeEvent(event)
        }

        let unsynced = try await store.fetchUnsyncedEvents(limit: 100_000)
        XCTAssertLessThanOrEqual(unsynced.count, GRDBLocalStore.maxSyncBatchSize)
        XCTAssertEqual(unsynced.count, 10)
    }

    // MARK: - Mark synced

    func testMarkEventsSyncedUpdatesOnlyGivenIds() async throws {
        let store = makeStore()
        let first = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-100),
            endedAt: referenceNow.addingTimeInterval(-90)
        )
        let second = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-80),
            endedAt: referenceNow.addingTimeInterval(-70)
        )
        try await store.writeEvent(first)
        try await store.writeEvent(second)

        try await store.markEventsSynced(ids: [first.eventID], syncedAt: referenceNow)

        let remaining = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertEqual(remaining.map(\.eventID), [second.eventID])
    }

    // MARK: - Tombstones

    func testTombstoneEventSetsDeletedAndResetsSyncedAtForResync() async throws {
        let store = makeStore()
        let event = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-60),
            endedAt: referenceNow,
            syncedAt: referenceNow
        )
        try await store.writeEvent(event)

        try await store.tombstoneEvent(id: event.eventID, at: referenceNow)

        let fetched = try await dbQueue.read { db in try ActivityEvent.fetchOne(db, key: event.eventID) }
        XCTAssertEqual(fetched?.deleted, true)
        XCTAssertNil(fetched?.syncedAt)

        // The tombstone itself must reappear in the outbox so it can be
        // pushed to the backend.
        let unsynced = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertEqual(unsynced.map(\.eventID), [event.eventID])
    }

    func testTombstoneEventIsNoOpForUnknownId() async throws {
        let store = makeStore()
        // Should not throw even though no row exists for this id.
        try await store.tombstoneEvent(id: UUID(), at: referenceNow)
    }

    // MARK: - Guarded mark-synced (RIZ-41)

    /// The common, happy-path case: nothing mutated the row between the
    /// batch being fetched and the push result coming back, so the snapshot
    /// still matches and the row is marked synced.
    func testMarkEventsSyncedMatchingStampsRowsWhoseSnapshotStillMatches() async throws {
        let store = makeStore()
        let event = makeEvent(startedAt: referenceNow.addingTimeInterval(-60), endedAt: referenceNow)
        try await store.writeEvent(event)

        try await store.markEventsSynced(
            matching: [SyncedRowSnapshot(eventID: event.eventID, deleted: false)],
            syncedAt: referenceNow
        )

        let remaining = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertTrue(remaining.isEmpty)
    }

    /// RIZ-38 review M1: if a row is tombstoned locally after its
    /// (pre-tombstone) push was already in flight, the snapshot captured at
    /// fetch time (`deleted: false`) no longer matches the row's current
    /// state (`deleted: true`) by the time the push result comes back. The
    /// guard must leave it pending so the tombstone itself gets pushed on
    /// the next cycle, rather than dropping it from the outbox.
    func testMarkEventsSyncedMatchingSkipsRowsTombstonedSinceTheSnapshotWasCaptured() async throws {
        let store = makeStore()
        let event = makeEvent(startedAt: referenceNow.addingTimeInterval(-60), endedAt: referenceNow)
        try await store.writeEvent(event)
        let snapshot = SyncedRowSnapshot(event: event)

        // Mutates the row after the snapshot was captured but before the
        // guarded mark-synced call — simulating a tombstone racing a push.
        try await store.tombstoneEvent(id: event.eventID, at: referenceNow)

        try await store.markEventsSynced(matching: [snapshot], syncedAt: referenceNow)

        let remaining = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertEqual(remaining.map(\.eventID), [event.eventID], "the tombstone must still be pending sync")
        let fetched = try await dbQueue.read { db in try ActivityEvent.fetchOne(db, key: event.eventID) }
        XCTAssertEqual(fetched?.deleted, true)
        XCTAssertNil(fetched?.syncedAt, "syncedAt must not be stamped once the row has moved on from the snapshot")
    }

    func testMarkEventsSyncedMatchingIgnoresUnknownIds() async throws {
        let store = makeStore()
        // Should not throw even though no row exists for this id.
        try await store.markEventsSynced(
            matching: [SyncedRowSnapshot(eventID: UUID(), deleted: false)],
            syncedAt: referenceNow
        )
    }

    func testMarkEventsSyncedMatchingIsNoOpForEmptySnapshotList() async throws {
        let store = makeStore()
        try await store.markEventsSynced(matching: [], syncedAt: referenceNow)
    }
}
