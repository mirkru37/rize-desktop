@testable import RizeDesktop
import XCTest

/// Exercises `LocalStore`'s protocol-extension defaults directly — the
/// unconditional `markEventsSynced(matching:syncedAt:)` fallback for
/// stores/fakes that don't need the guarded, state-checking version
/// `GRDBLocalStore` overrides — per the doc comment on
/// `LocalStore.markEventsSynced(matching:syncedAt:)`.
final class LocalStoreTests: XCTestCase {
    /// A minimal `LocalStore` that records the ids it was told to mark
    /// synced, and deliberately does not override
    /// `markEventsSynced(matching:syncedAt:)`, so calling that method
    /// resolves to the protocol's default implementation under test.
    private actor RecordingLocalStore: LocalStore {
        private(set) var markedSyncedIDs: [UUID] = []

        func writeEvent(_ event: ActivityEvent) async throws {}
        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}
        func tombstoneSession(id: UUID, at date: Date) async throws {}
        func fetchTodayActivity() async throws -> [ActivityEvent] {
            []
        }

        func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
            []
        }

        func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {
            markedSyncedIDs = ids
        }
    }

    func testDefaultMaxSyncBatchSizeIs500() {
        XCTAssertEqual(RecordingLocalStore.maxSyncBatchSize, 500)
    }

    func testDefaultMarkEventsSyncedMatchingDelegatesUnconditionallyToTheIDsOverload() async throws {
        let store = RecordingLocalStore()
        let deletedID = UUID()
        let liveID = UUID()
        let snapshots = [
            SyncedRowSnapshot(eventID: deletedID, deleted: true),
            SyncedRowSnapshot(eventID: liveID, deleted: false)
        ]

        try await store.markEventsSynced(matching: snapshots, syncedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let markedSyncedIDs = await store.markedSyncedIDs
        XCTAssertEqual(Set(markedSyncedIDs), Set([deletedID, liveID]))
    }

    func testSyncedRowSnapshotFromEventCapturesIDAndDeletedFlag() {
        let event = ActivityEvent(
            eventID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: Date(timeIntervalSince1970: 1_800_000_060),
            type: .appActive,
            appBundleID: "com.acme.Editor",
            insertedAt: Date(timeIntervalSince1970: 1_800_000_060),
            deleted: true
        )

        let snapshot = SyncedRowSnapshot(event: event)

        XCTAssertEqual(snapshot.eventID, event.eventID)
        XCTAssertTrue(snapshot.deleted)
    }
}
