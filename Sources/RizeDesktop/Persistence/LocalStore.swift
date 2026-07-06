import Foundation

/// The offline-first local store's public API. UI and sync-layer code
/// depend on this protocol rather than on GRDB directly, so the storage
/// engine is swappable and easily faked in tests.
///
/// See `documentation/architecture-desktop.md` §Offline-First Store & Sync
/// Loop: `activity_events` are always written locally first, a batch of at
/// most 500 unsynced rows is handed to the Sync Client, and a row is marked
/// synced only after the server acknowledges it — never optimistically.
protocol LocalStore: Sendable {
    /// The sync protocol's per-request cap on outbox batch size
    /// (`documentation/sync-protocol.md` §Push).
    static var maxSyncBatchSize: Int { get }

    /// Writes a closed activity event to the store. Because the primary key
    /// is the client-generated `eventID`, calling this again with the same
    /// id (with `deleted` now `true`) performs the sanctioned tombstone
    /// update rather than creating a duplicate row.
    func writeEvent(_ event: ActivityEvent) async throws

    /// Marks an existing event as deleted (tombstoned) and clears its
    /// `syncedAt`, so the tombstone itself is picked up by the next sync
    /// batch. No-ops if the event does not exist.
    func tombstoneEvent(id: UUID, at date: Date) async throws

    /// Inserts or updates a focus/manual session, keyed by `id`.
    func upsertSession(_ session: FocusSession) async throws

    /// Returns all non-deleted activity events whose `startedAt` falls
    /// within "today", as defined by the store's injected clock/calendar.
    func fetchTodayActivity() async throws -> [ActivityEvent]

    /// Returns up to `limit` activity events pending sync (`syncedAt ==
    /// nil`), oldest first. `limit` is clamped to `maxSyncBatchSize`.
    func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent]

    /// Marks the given events as synced as of `date`. Ids that don't exist
    /// are silently ignored.
    func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws

    /// Marks events as synced, but only the rows whose `deleted` flag still
    /// matches the snapshot captured when the outbox batch was read.
    ///
    /// The push cycle fetches a batch, sends it over the network, and only
    /// then marks it synced — an inherently non-atomic sequence. If a row is
    /// tombstoned locally while its (pre-tombstone) push is in flight, the
    /// server accepted the stale version, but the local row now needs a
    /// *second* push (the tombstone itself). Marking it synced unconditionally
    /// at that point would drop the tombstone from the outbox forever. This
    /// guard re-checks `deleted` at write time and only stamps `syncedAt` for
    /// rows that haven't changed since they were captured, leaving mutated
    /// rows pending for the next cycle instead.
    func markEventsSynced(matching snapshots: [SyncedRowSnapshot], syncedAt date: Date) async throws
}

/// A row's `deleted` state as observed when an outbox batch was fetched, used
/// by `markEventsSynced(matching:syncedAt:)` to detect concurrent mutation.
struct SyncedRowSnapshot: Equatable {
    let eventID: UUID
    let deleted: Bool

    init(eventID: UUID, deleted: Bool) {
        self.eventID = eventID
        self.deleted = deleted
    }

    init(event: ActivityEvent) {
        eventID = event.eventID
        deleted = event.deleted
    }
}

extension LocalStore {
    static var maxSyncBatchSize: Int {
        500
    }

    /// Default fallback for stores/fakes that don't need the guard's
    /// precision (e.g. tracking-focused test doubles that never exercise
    /// sync): marks everything in the snapshot unconditionally.
    /// `GRDBLocalStore` overrides this with the real guarded update.
    func markEventsSynced(matching snapshots: [SyncedRowSnapshot], syncedAt date: Date) async throws {
        try await markEventsSynced(ids: snapshots.map(\.eventID), syncedAt: date)
    }
}
