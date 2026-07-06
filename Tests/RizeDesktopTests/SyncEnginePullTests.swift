import GRDB
@testable import RizeDesktop
import XCTest

/// Pull-side coverage for `SyncEngine.runCycle()`: upserts, tombstones,
/// cursor persistence, and paging. Split out of `SyncEngineTests` (which
/// covers push) purely to stay under SwiftLint's `type_body_length` limit —
/// same fixtures, same real `GRDBLocalStore`/`FakeSyncAPIClient` setup.
final class SyncEnginePullTests: XCTestCase {
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
