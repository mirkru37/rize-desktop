import Foundation
import GRDB

/// The kind of user-initiated session. Mirrors the `kind` check constraint
/// on the server's `focus_sessions` table
/// (`documentation/database-schema.md` §focus_sessions).
enum FocusSessionKind: String, Codable, DatabaseValueConvertible {
    case focus
    case sessionBreak = "break"
    case meeting
}

/// Lifecycle state of a session. Mirrors the `status` check constraint on
/// the server's `focus_sessions` table.
enum FocusSessionStatus: String, Codable, DatabaseValueConvertible {
    case running
    case completed
    case abandoned
}

/// An explicit, user-initiated session (a focus block, a break, or a
/// meeting), as opposed to the automatically captured rows in
/// `ActivityEvent`.
///
/// This is a mutable, last-write-wins entity per
/// `documentation/sync-protocol.md` §Entity Classes: unlike `ActivityEvent`,
/// rows are legitimately edited after creation (e.g. completing a running
/// session), and the client-supplied `updatedAt` is what the server uses to
/// resolve conflicting writes across devices. `pendingSync` is a local-only
/// bookkeeping column (never sent over the wire) that mirrors the same
/// "has this reached the backend yet" concept `ActivityEvent.syncedAt`
/// provides for the append-only side of the model.
struct FocusSession: Codable, Equatable {
    /// Client-generated UUIDv7. Primary key.
    var id: UUID
    var deviceID: UUID?
    var projectID: UUID?
    var kind: FocusSessionKind
    var plannedDurationS: Int?
    var startedAt: Date
    /// Nil while the session is still `running`.
    var endedAt: Date?
    var status: FocusSessionStatus
    var note: String?
    var createdAt: Date
    var updatedAt: Date
    /// Soft-delete tombstone, matching the server's `deleted_at` convention
    /// for mutable entities (as opposed to `ActivityEvent`'s plain
    /// `deleted` boolean flag).
    var deletedAt: Date?
    /// Local-only: `true` until this version of the row has been pushed to
    /// and acknowledged by the backend.
    var pendingSync: Bool

    init(
        id: UUID,
        deviceID: UUID? = nil,
        projectID: UUID? = nil,
        kind: FocusSessionKind,
        plannedDurationS: Int? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        status: FocusSessionStatus,
        note: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil,
        pendingSync: Bool = true
    ) {
        self.id = id
        self.deviceID = deviceID
        self.projectID = projectID
        self.kind = kind
        self.plannedDurationS = plannedDurationS
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.pendingSync = pendingSync
    }
}

extension FocusSession: FetchableRecord, PersistableRecord {
    static let databaseTableName = "focus_sessions"
}
