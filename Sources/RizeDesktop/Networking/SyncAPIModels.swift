import Foundation

/// One outbox item in a `POST /v1/sync/events` request, per
/// `documentation/sync-protocol.md` §Push. The desktop client only ever
/// produces `activity_event` items.
struct SyncPushItemDTO: Encodable {
    var entityType: String
    var data: ActivityEventPushDataDTO

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case data
    }
}

struct ActivityEventPushDataDTO: Encodable {
    var eventID: UUID
    var startedAt: Date
    var endedAt: Date
    var appBundleID: String?
    var windowTitle: String?
    var precision: String
    var deleted: Bool

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case appBundleID = "app_bundle_id"
        case windowTitle = "window_title"
        case precision, deleted
    }
}

struct SyncPushRequestDTO: Encodable {
    var deviceID: String
    var items: [SyncPushItemDTO]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case items
    }
}

/// The per-item outcome the server returns for each pushed item, in request
/// order, per `documentation/sync-protocol.md` §Push Response schema.
struct SyncPushResultDTO: Decodable {
    enum Status: String, Decodable {
        case applied
        case duplicate
        case invalid
    }

    var index: Int
    var entityType: String
    var eventID: String?
    var id: String?
    var status: Status
    var serverSeq: Int?
    var error: ProblemLikeError?

    enum CodingKeys: String, CodingKey {
        case index
        case entityType = "entity_type"
        case eventID = "event_id"
        case id
        case status
        case serverSeq = "server_seq"
        case error
    }

    struct ProblemLikeError: Decodable {
        var code: String
        var message: String
    }
}

struct SyncPushResponseDTO: Decodable {
    var results: [SyncPushResultDTO]
}

/// One upserted `activity_events` row from `GET /v1/sync/changes`, per
/// `documentation/sync-protocol.md` §Pull Response schema.
struct ActivityEventUpsertDTO: Decodable {
    var eventID: UUID
    var startedAt: Date
    var endedAt: Date
    var appBundleID: String?
    var windowTitle: String?
    var precision: String
    var serverSeq: Int

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case appBundleID = "app_bundle_id"
        case windowTitle = "window_title"
        case precision
        case serverSeq = "server_seq"
    }
}

/// A tombstone entry. `activity_events` tombstones key on `event_id`; every
/// other entity type keys on `id` (`documentation/sync-protocol.md` §Pull).
/// Both are decoded as optional so one `TombstoneDTO` shape covers every
/// entity type's tombstone array.
struct TombstoneDTO: Decodable {
    var eventID: UUID?
    var id: UUID?
    var serverSeq: Int

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case id
        case serverSeq = "server_seq"
    }

    /// The identifier this tombstone applies to, regardless of which key it
    /// arrived under.
    var recordID: UUID? {
        eventID ?? id
    }
}

struct FocusSessionUpsertDTO: Decodable {
    var id: UUID
    var updatedAt: Date
    var startedAt: Date
    var endedAt: Date?
    var projectID: UUID?
    var label: String?
    var deleted: Bool
    var serverSeq: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case projectID = "project_id"
        case label, deleted
        case serverSeq = "server_seq"
    }
}

/// A generic `{ upserts, tombstones }` pair. Entity types this client
/// doesn't yet persist locally (`projects`, `tags`, `user_app_settings`,
/// `aggregates`) are decoded as opaque JSON so the response can still be
/// parsed as a whole, but are not applied to `LocalStore` — see
/// `SyncEngine.applyChanges` for the rationale.
struct ChangeSetDTO<Upsert: Decodable & Sendable>: Decodable {
    var upserts: [Upsert]
    var tombstones: [TombstoneDTO]
}

struct SyncChangesDTO: Decodable {
    var activityEvents: ChangeSetDTO<ActivityEventUpsertDTO>?
    var focusSessions: ChangeSetDTO<FocusSessionUpsertDTO>?

    enum CodingKeys: String, CodingKey {
        case activityEvents = "activity_events"
        case focusSessions = "focus_sessions"
    }
}

struct SyncChangesResponseDTO: Decodable {
    var changes: SyncChangesDTO
    var nextCursor: String
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case changes
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}
