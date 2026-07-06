import Foundation

/// The outcome of a single `SyncEngine.runCycle()`, surfaced to
/// `SyncCoordinator` for backoff/status decisions.
struct SyncCycleResult: Equatable {
    var pushedCount: Int
    var pulledPageCount: Int
    var skippedNilDeviceIDCount: Int
}

/// Implements one push-then-pull sync cycle per
/// `documentation/sync-protocol.md` §Flow and
/// `documentation/architecture-desktop.md` §Offline-First Store & Sync Loop:
///
/// 1. Fetch an outbox batch (≤500) from `LocalStore`.
/// 2. Push it; apply each item's own result (`applied`/`duplicate` -> mark
///    synced with the state-guard; `invalid` -> leave pending).
/// 3. Pull changes since the stored cursor, applying upserts/tombstones and
///    persisting the new cursor after each page.
///
/// Not an actor: `LocalStore` and the injected API client are themselves
/// `Sendable`/actor-isolated, and `SyncEngine` holds no mutable state of its
/// own between calls, so a plain `Sendable` struct is sufficient and keeps
/// `runCycle()` straightforwardly testable.
struct SyncEngine {
    private let localStore: LocalStore
    private let syncAPI: SyncAPIClient
    private let cursorStore: SyncCursorStore
    private let tokenManager: AuthTokenManager
    private let clock: Clock

    init(
        localStore: LocalStore,
        syncAPI: SyncAPIClient,
        cursorStore: SyncCursorStore,
        tokenManager: AuthTokenManager,
        clock: Clock = SystemClock()
    ) {
        self.localStore = localStore
        self.syncAPI = syncAPI
        self.cursorStore = cursorStore
        self.tokenManager = tokenManager
        self.clock = clock
    }

    /// Runs exactly one push-then-pull cycle. Callers that want continuous
    /// syncing (e.g. `SyncCoordinator`) call this repeatedly on a timer.
    @discardableResult
    func runCycle() async throws -> SyncCycleResult {
        let pushOutcome = try await push()
        let pulledPages = try await pull()
        return SyncCycleResult(
            pushedCount: pushOutcome.pushedCount,
            pulledPageCount: pulledPages,
            skippedNilDeviceIDCount: pushOutcome.skippedNilDeviceIDCount
        )
    }

    // MARK: - Push

    private struct PushOutcome {
        var pushedCount: Int
        var skippedNilDeviceIDCount: Int
    }

    /// Pushes a single outbox batch. One batch per cycle keeps the loop
    /// simple and bounded — a larger outbox drains over successive 60s
    /// cycles rather than one unbounded internal loop, which also avoids an
    /// infinite spin if the same `invalid` item keeps coming back in the
    /// batch (see the doc comment on `LocalStore.markEventsSynced(matching:
    /// syncedAt:)`).
    private func push() async throws -> PushOutcome {
        let batch = try await localStore.fetchUnsyncedEvents(limit: type(of: localStore).maxSyncBatchSize)
        guard !batch.isEmpty else {
            return PushOutcome(pushedCount: 0, skippedNilDeviceIDCount: 0)
        }

        // RIZ-38 review L5: never push events with a nil deviceID (the
        // device hasn't finished registration/backfill yet). They stay in
        // the outbox — unsynced — for a later cycle once a device id has
        // been assigned to them.
        let pushable = batch.filter { $0.deviceID != nil }
        let skippedCount = batch.count - pushable.count

        guard !pushable.isEmpty, let deviceID = await tokenManager.persistedDeviceID() else {
            return PushOutcome(pushedCount: 0, skippedNilDeviceIDCount: skippedCount)
        }

        let items = pushable.map(Self.makePushItem)
        let results = try await syncAPI.pushEvents(items, deviceID: deviceID.uuidString)

        var synced: [SyncedRowSnapshot] = []
        for (event, result) in zip(pushable, results) {
            switch result.status {
            case .applied, .duplicate:
                synced.append(SyncedRowSnapshot(event: event))
            case .invalid:
                continue
            }
        }

        try await localStore.markEventsSynced(matching: synced, syncedAt: clock.now())
        return PushOutcome(pushedCount: synced.count, skippedNilDeviceIDCount: skippedCount)
    }

    private static func makePushItem(from event: ActivityEvent) -> SyncPushItemDTO {
        SyncPushItemDTO(
            entityType: "activity_event",
            data: ActivityEventPushDataDTO(
                eventID: event.eventID,
                startedAt: event.startedAt,
                endedAt: event.endedAt,
                appBundleID: event.appBundleID,
                windowTitle: event.windowTitle,
                precision: event.precision.rawValue,
                deleted: event.deleted
            )
        )
    }

    // MARK: - Pull

    /// Pulls every available page from the stored cursor, applying each
    /// page and persisting its `next_cursor` immediately after. Pulls are
    /// idempotent by design (`documentation/sync-protocol.md` §Pull), so
    /// even without a single cross-page DB transaction, re-applying a page
    /// after a crash is safe — see the note on `SyncCoordinator` for the
    /// scope of the transactional guarantee this implementation provides.
    private func pull() async throws -> Int {
        var pageCount = 0
        var hasMore = true

        while hasMore {
            let cursor = cursorStore.currentCursor()
            let response = try await syncAPI.fetchChanges(cursor: cursor, limit: 500)
            try await apply(response.changes)
            try cursorStore.save(response.nextCursor)
            pageCount += 1
            hasMore = response.hasMore
        }

        return pageCount
    }

    /// Applies a pulled page to `LocalStore`. Both `activity_events` and
    /// `focus_sessions` are fully applied (upserts + tombstones), tombstones
    /// after upserts so an id that is both upserted and tombstoned within
    /// the same page ends deleted. `focus_sessions` upserts are applied via
    /// `LocalStore.upsertSession` — blind overwrite, since `LocalStore` has
    /// no fetch-by-id to LWW-compare against the incoming `updated_at` (the
    /// server has already resolved LWW before this page was produced, so
    /// this only matters for a local edit made after the page was generated
    /// but before it was applied, a narrow race). Other entity
    /// types (`projects`, `tags`, `user_app_settings`, `aggregates`) have no
    /// local storage yet, so they are decoded but intentionally not applied
    /// here — extending `LocalStore` for them is out of RIZ-41's scope.
    private func apply(_ changes: SyncChangesDTO) async throws {
        if let activityEvents = changes.activityEvents {
            for upsert in activityEvents.upserts {
                try await localStore.writeEvent(Self.makeActivityEvent(from: upsert, insertedAt: clock.now()))
            }
            for tombstone in activityEvents.tombstones {
                guard let recordID = tombstone.recordID else {
                    continue
                }
                try await localStore.tombstoneEvent(id: recordID, at: clock.now())
            }
        }

        if let focusSessions = changes.focusSessions {
            for upsert in focusSessions.upserts {
                try await localStore.upsertSession(Self.makeFocusSession(from: upsert))
            }
            for tombstone in focusSessions.tombstones {
                guard let recordID = tombstone.recordID else {
                    continue
                }
                try await localStore.tombstoneSession(id: recordID, at: clock.now())
            }
        }
    }

    private static func makeActivityEvent(from dto: ActivityEventUpsertDTO, insertedAt: Date) -> ActivityEvent {
        ActivityEvent(
            eventID: dto.eventID,
            startedAt: dto.startedAt,
            endedAt: dto.endedAt,
            type: .appActive,
            source: .desktop,
            precision: ActivityEventPrecision(rawValue: dto.precision) ?? .exact,
            appBundleID: dto.appBundleID,
            windowTitle: dto.windowTitle,
            deleted: false,
            insertedAt: insertedAt,
            // Pulled rows are, by definition, already known to the server.
            syncedAt: insertedAt
        )
    }

    private static func makeFocusSession(from dto: FocusSessionUpsertDTO) -> FocusSession {
        FocusSession(
            id: dto.id,
            projectID: dto.projectID,
            kind: .focus,
            startedAt: dto.startedAt,
            endedAt: dto.endedAt,
            status: dto.endedAt == nil ? .running : .completed,
            note: dto.label,
            createdAt: dto.startedAt,
            updatedAt: dto.updatedAt,
            deletedAt: dto.deleted ? dto.updatedAt : nil,
            pendingSync: false
        )
    }
}
