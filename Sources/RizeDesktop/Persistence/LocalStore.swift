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
}

extension LocalStore {
    static var maxSyncBatchSize: Int {
        500
    }
}
