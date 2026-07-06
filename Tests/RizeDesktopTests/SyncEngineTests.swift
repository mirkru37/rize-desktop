import GRDB
@testable import RizeDesktop
import XCTest

/// Exercises `SyncEngine.runCycle()` against a real `GRDBLocalStore`
/// (in-memory SQLite) and a `FakeSyncAPIClient`, per
/// `documentation/sync-protocol.md` §Flow and
/// `documentation/architecture-desktop.md` §Offline-First Store & Sync Loop.
/// Using the real store (rather than a hand-rolled fake) is what lets these
/// tests exercise the actual guarded mark-synced query end to end.
final class SyncEngineTests: XCTestCase {
    private var dbQueue: DatabaseQueue!
    private var referenceNow: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbQueue = try DatabaseQueue()
        try DatabaseMigrations.makeMigrator().migrate(dbQueue)
        referenceNow = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDown() {
        dbQueue = nil
        referenceNow = nil
        super.tearDown()
    }

    private func makeStore() -> GRDBLocalStore {
        GRDBLocalStore(dbWriter: dbQueue, clock: FixedTestClock(date: referenceNow))
    }

    private func makeEngine(
        store: LocalStore,
        syncAPI: SyncAPIClient,
        cursorStore: SyncCursorStore = InMemorySyncCursorStore(),
        deviceID: UUID? = UUID()
    ) async -> SyncEngine {
        let authAPI = FakeAuthAPIClient()
        let storage = InMemoryAuthTokenStorage()
        if let deviceID {
            try? storage.saveDeviceID(deviceID)
        }
        let tokenManager = AuthTokenManager(api: authAPI, storage: storage)
        return SyncEngine(
            localStore: store,
            syncAPI: syncAPI,
            cursorStore: cursorStore,
            tokenManager: tokenManager,
            clock: FixedTestClock(date: referenceNow)
        )
    }

    private func makeEvent(
        id: UUID = UUID(),
        deviceID: UUID? = UUID(),
        startedAt: Date,
        endedAt: Date,
        deleted: Bool = false
    ) -> ActivityEvent {
        ActivityEvent(
            eventID: id,
            deviceID: deviceID,
            startedAt: startedAt,
            endedAt: endedAt,
            type: .appActive,
            appBundleID: "com.apple.dt.Xcode",
            deleted: deleted,
            insertedAt: startedAt
        )
    }

    // MARK: - Push batching / cap

    func testPushSendsAtMostOneBatchCappedAtProtocolMaximum() async throws {
        let store = makeStore()
        for offset in 0 ..< 505 {
            let event = makeEvent(
                startedAt: referenceNow.addingTimeInterval(TimeInterval(-offset - 1)),
                endedAt: referenceNow.addingTimeInterval(TimeInterval(-offset))
            )
            try await store.writeEvent(event)
        }
        let syncAPI = FakeSyncAPIClient()
        let engine = await makeEngine(store: store, syncAPI: syncAPI)

        try await engine.runCycle()

        let batches = await syncAPI.pushedBatches
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, GRDBLocalStore.maxSyncBatchSize)
    }

    // MARK: - Per-item result application

    func testPushMarksAppliedAndDuplicateSyncedButLeavesInvalidPending() async throws {
        let store = makeStore()
        let applied = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-300),
            endedAt: referenceNow.addingTimeInterval(-290)
        )
        let duplicate = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-200),
            endedAt: referenceNow.addingTimeInterval(-190)
        )
        let invalid = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-100),
            endedAt: referenceNow.addingTimeInterval(-90)
        )
        try await store.writeEvent(applied)
        try await store.writeEvent(duplicate)
        try await store.writeEvent(invalid)

        let syncAPI = FakeSyncAPIClient()
        await syncAPI.enqueuePush(.success([
            SyncPushResultDTO(
                index: 0,
                entityType: "activity_event",
                eventID: applied.eventID.uuidString,
                id: nil,
                status: .applied,
                serverSeq: 1,
                error: nil
            ),
            SyncPushResultDTO(
                index: 1,
                entityType: "activity_event",
                eventID: duplicate.eventID.uuidString,
                id: nil,
                status: .duplicate,
                serverSeq: nil,
                error: nil
            ),
            SyncPushResultDTO(
                index: 2,
                entityType: "activity_event",
                eventID: invalid.eventID.uuidString,
                id: nil,
                status: .invalid,
                serverSeq: nil,
                error: .init(code: "VALIDATION_ERROR", message: "bad")
            )
        ]))
        let engine = await makeEngine(store: store, syncAPI: syncAPI)

        try await engine.runCycle()

        let stillUnsynced = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertEqual(stillUnsynced.map(\.eventID), [invalid.eventID])
    }

    // MARK: - Nil deviceID exclusion (RIZ-38 review L5)

    func testPushExcludesEventsWithNilDeviceIDAndLeavesThemPending() async throws {
        let store = makeStore()
        let withDevice = makeEvent(
            deviceID: UUID(),
            startedAt: referenceNow.addingTimeInterval(-200),
            endedAt: referenceNow.addingTimeInterval(-190)
        )
        let withoutDevice = makeEvent(
            deviceID: nil,
            startedAt: referenceNow.addingTimeInterval(-100),
            endedAt: referenceNow.addingTimeInterval(-90)
        )
        try await store.writeEvent(withDevice)
        try await store.writeEvent(withoutDevice)

        let syncAPI = FakeSyncAPIClient()
        let engine = await makeEngine(store: store, syncAPI: syncAPI)

        let result = try await engine.runCycle()

        let batches = await syncAPI.pushedBatches
        XCTAssertEqual(batches.first?.map(\.data.eventID), [withDevice.eventID])
        XCTAssertEqual(result.skippedNilDeviceIDCount, 1)

        let stillUnsynced = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertEqual(stillUnsynced.map(\.eventID), [withoutDevice.eventID])
    }

    // MARK: - Idempotent retry

    func testPushRetryAfterNetworkFailureEventuallySucceedsWithoutDuplicating() async throws {
        let store = makeStore()
        let event = makeEvent(startedAt: referenceNow.addingTimeInterval(-60), endedAt: referenceNow)
        try await store.writeEvent(event)

        let syncAPI = FakeSyncAPIClient()
        await syncAPI.enqueuePush(.failure(TestError.network))
        let engine = await makeEngine(store: store, syncAPI: syncAPI)

        do {
            try await engine.runCycle()
            XCTFail("expected the first cycle to throw")
        } catch {
            // expected: simulated network failure
        }

        var stillUnsynced = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertEqual(stillUnsynced.map(\.eventID), [event.eventID])

        // Retry: same row, same idempotency key, this time the server
        // accepts it.
        try await engine.runCycle()

        stillUnsynced = try await store.fetchUnsyncedEvents(limit: 500)
        XCTAssertTrue(stillUnsynced.isEmpty)

        let batches = await syncAPI.pushedBatches
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].map(\.data.eventID), [event.eventID])
        XCTAssertEqual(
            batches[1].map(\.data.eventID),
            [event.eventID],
            "retry must resend the same identifier, never a new one"
        )

        let rowCount = try await dbQueue.read { db in try ActivityEvent.fetchCount(db) }
        XCTAssertEqual(rowCount, 1, "a retried push must never duplicate the local row")
    }

    // MARK: - Pull: upserts, tombstones, cursor persistence

    func testPullAppliesUpsertsAndTombstonesAndPersistsCursor() async throws {
        let store = makeStore()
        let existing = makeEvent(
            startedAt: referenceNow.addingTimeInterval(-500),
            endedAt: referenceNow.addingTimeInterval(-490)
        )
        try await store.writeEvent(existing)
        try await store.markEventsSynced(ids: [existing.eventID], syncedAt: referenceNow)

        let upsertedID = UUID()
        let response = SyncChangesResponseDTO(
            changes: SyncChangesDTO(
                activityEvents: ChangeSetDTO(
                    upserts: [
                        ActivityEventUpsertDTO(
                            eventID: upsertedID,
                            startedAt: referenceNow.addingTimeInterval(-60),
                            endedAt: referenceNow,
                            appBundleID: "com.tinyspeck.slackmacgap",
                            windowTitle: nil,
                            precision: "exact",
                            serverSeq: 100
                        )
                    ],
                    tombstones: [TombstoneDTO(eventID: existing.eventID, id: nil, serverSeq: 101)]
                ),
                focusSessions: nil
            ),
            nextCursor: "cursor-101",
            hasMore: false
        )
        let syncAPI = FakeSyncAPIClient()
        await syncAPI.enqueueFetch(.success(response))
        let cursorStore = InMemorySyncCursorStore()
        let engine = await makeEngine(store: store, syncAPI: syncAPI, cursorStore: cursorStore)

        try await engine.runCycle()

        let upserted = try await dbQueue.read { db in try ActivityEvent.fetchOne(db, key: upsertedID) }
        XCTAssertEqual(upserted?.appBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertNotNil(upserted?.syncedAt, "pulled rows are already known to the server")

        let tombstoned = try await dbQueue.read { db in try ActivityEvent.fetchOne(db, key: existing.eventID) }
        XCTAssertEqual(tombstoned?.deleted, true)

        XCTAssertEqual(cursorStore.currentCursor(), "cursor-101")
    }

    func testPullAppliesFocusSessionTombstone() async throws {
        let store = makeStore()
        let sessionID = UUID()
        let existing = FocusSession(
            id: sessionID,
            kind: .focus,
            startedAt: referenceNow.addingTimeInterval(-600),
            status: .running,
            createdAt: referenceNow.addingTimeInterval(-600),
            updatedAt: referenceNow.addingTimeInterval(-600)
        )
        try await store.upsertSession(existing)

        let response = SyncChangesResponseDTO(
            changes: SyncChangesDTO(
                activityEvents: nil,
                focusSessions: ChangeSetDTO(
                    upserts: [],
                    tombstones: [TombstoneDTO(eventID: nil, id: sessionID, serverSeq: 200)]
                )
            ),
            nextCursor: "cursor-200",
            hasMore: false
        )
        let syncAPI = FakeSyncAPIClient()
        await syncAPI.enqueueFetch(.success(response))
        let cursorStore = InMemorySyncCursorStore()
        let engine = await makeEngine(store: store, syncAPI: syncAPI, cursorStore: cursorStore)

        try await engine.runCycle()

        let fetched = try await dbQueue.read { db in try FocusSession.fetchOne(db, key: sessionID) }
        XCTAssertNotNil(fetched?.deletedAt, "a pulled tombstone must soft-delete the local session")
        XCTAssertEqual(cursorStore.currentCursor(), "cursor-200")
    }

    func testPullAppliesUpsertThenTombstoneForSameFocusSessionInOnePage() async throws {
        let store = makeStore()
        let sessionID = UUID()

        let response = SyncChangesResponseDTO(
            changes: SyncChangesDTO(
                activityEvents: nil,
                focusSessions: ChangeSetDTO(
                    upserts: [
                        FocusSessionUpsertDTO(
                            id: sessionID,
                            updatedAt: referenceNow.addingTimeInterval(-60),
                            startedAt: referenceNow.addingTimeInterval(-600),
                            endedAt: referenceNow,
                            projectID: nil,
                            label: "Deep work",
                            deleted: false,
                            serverSeq: 300
                        )
                    ],
                    tombstones: [TombstoneDTO(eventID: nil, id: sessionID, serverSeq: 301)]
                )
            ),
            nextCursor: "cursor-301",
            hasMore: false
        )
        let syncAPI = FakeSyncAPIClient()
        await syncAPI.enqueueFetch(.success(response))
        let cursorStore = InMemorySyncCursorStore()
        let engine = await makeEngine(store: store, syncAPI: syncAPI, cursorStore: cursorStore)

        try await engine.runCycle()

        let fetched = try await dbQueue.read { db in try FocusSession.fetchOne(db, key: sessionID) }
        XCTAssertNotNil(
            fetched?.deletedAt,
            "an id upserted and tombstoned in the same page must end deleted"
        )
        XCTAssertEqual(cursorStore.currentCursor(), "cursor-301")
    }

    func testPullPagesUntilHasMoreIsFalse() async throws {
        let store = makeStore()
        let firstPage = SyncChangesResponseDTO(
            changes: SyncChangesDTO(activityEvents: nil, focusSessions: nil),
            nextCursor: "cursor-1",
            hasMore: true
        )
        let secondPage = SyncChangesResponseDTO(
            changes: SyncChangesDTO(activityEvents: nil, focusSessions: nil),
            nextCursor: "cursor-2",
            hasMore: false
        )
        let syncAPI = FakeSyncAPIClient()
        await syncAPI.enqueueFetch(.success(firstPage))
        await syncAPI.enqueueFetch(.success(secondPage))
        let cursorStore = InMemorySyncCursorStore()
        let engine = await makeEngine(store: store, syncAPI: syncAPI, cursorStore: cursorStore)

        try await engine.runCycle()

        let fetchedCursors = await syncAPI.fetchedCursors
        XCTAssertEqual(fetchedCursors, [nil, "cursor-1"])
        XCTAssertEqual(cursorStore.currentCursor(), "cursor-2")
    }
}
