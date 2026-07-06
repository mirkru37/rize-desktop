import Foundation
import GRDB

/// The kind of activity segment a row represents.
///
/// Mirrors the `type` check constraint on the server's `activity_events`
/// table (`documentation/database-schema.md` §activity_events). The desktop
/// client only ever writes `appActive`, `idle`, `locked`, and `manual`;
/// `mobileUsage` exists purely so the local schema mirrors the full server
/// contract rather than a client-specific subset.
enum ActivityEventType: String, Codable, DatabaseValueConvertible {
    case appActive = "app_active"
    case idle
    case locked
    case mobileUsage = "mobile_usage"
    case manual
}

/// The client that produced a row. Always `desktop` for events written by
/// this app; the other cases exist so the local schema mirrors the server's
/// `source` check constraint.
enum ActivityEventSource: String, Codable, DatabaseValueConvertible {
    case desktop
    case mobile
    case manual
}

/// Whether an event's boundaries reflect directly observed activity
/// (`exact`) or were derived from a coarser threshold signal (`approximate`).
/// See `documentation/sync-protocol.md` §Precision Semantics.
enum ActivityEventPrecision: String, Codable, DatabaseValueConvertible {
    case exact
    case approximate
}

/// A single immutable segment of tracked activity, closed by the Tracking
/// Engine once a session ends (app/window change, or a state-machine
/// transition out of `active`).
///
/// This record mirrors the server's `activity_events` table
/// (`documentation/database-schema.md` §activity_events) with one addition:
/// `syncedAt`, a local-only bookkeeping column (never sent over the wire)
/// that lets `LocalStore` track which rows still need to reach the backend.
/// Everything else matches the sync protocol's per-item payload
/// (`documentation/sync-protocol.md` §Push).
///
/// Rows are immutable once written, with a single sanctioned exception: a
/// tombstone push (or local delete) sets `deleted = true` on the existing
/// row rather than inserting a new one, per the append-only/tombstone rule
/// in `documentation/sync-protocol.md` §Entity Classes.
struct ActivityEvent: Codable, Equatable {
    /// Client-generated UUIDv7. Primary key; also the sync idempotency key.
    var eventID: UUID
    /// The device this event was recorded on. Nil until the device has
    /// completed registration with the backend.
    var deviceID: UUID?
    var startedAt: Date
    var endedAt: Date
    var type: ActivityEventType
    var source: ActivityEventSource
    var precision: ActivityEventPrecision
    var appBundleID: String?
    var windowTitle: String?
    var url: String?
    var categoryID: UUID?
    var projectID: UUID?
    /// Tombstone flag. `true` means this row has been deleted; the row
    /// itself is retained (per the append-only/tombstone sync rule) rather
    /// than removed from the table.
    var deleted: Bool
    var insertedAt: Date
    /// Local-only: set once the backend has acknowledged this row. `nil`
    /// means the row is still pending in the sync outbox.
    var syncedAt: Date?

    init(
        eventID: UUID,
        deviceID: UUID? = nil,
        startedAt: Date,
        endedAt: Date,
        type: ActivityEventType,
        source: ActivityEventSource = .desktop,
        precision: ActivityEventPrecision = .exact,
        appBundleID: String? = nil,
        windowTitle: String? = nil,
        url: String? = nil,
        categoryID: UUID? = nil,
        projectID: UUID? = nil,
        deleted: Bool = false,
        insertedAt: Date,
        syncedAt: Date? = nil
    ) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.type = type
        self.source = source
        self.precision = precision
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.url = url
        self.categoryID = categoryID
        self.projectID = projectID
        self.deleted = deleted
        self.insertedAt = insertedAt
        self.syncedAt = syncedAt
    }
}

extension ActivityEvent: FetchableRecord, PersistableRecord {
    static let databaseTableName = "activity_events"
}
