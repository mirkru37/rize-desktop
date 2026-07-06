import Foundation
import GRDB

/// GRDB-backed implementation of `LocalStore`.
final class GRDBLocalStore: LocalStore {
    private let dbWriter: any DatabaseWriter
    private let clock: Clock
    private let calendar: Calendar

    /// - Parameters:
    ///   - dbWriter: An already-migrated GRDB writer (`DatabaseQueue` or
    ///     `DatabasePool`). Use `DatabaseManager` to open one with
    ///     migrations applied.
    ///   - clock: Injected so "today" and sync timestamps are deterministic
    ///     in tests. Defaults to the system clock in production.
    ///   - calendar: Used to compute the "today" boundary for
    ///     `fetchTodayActivity()`.
    init(dbWriter: any DatabaseWriter, clock: Clock = SystemClock(), calendar: Calendar = .current) {
        self.dbWriter = dbWriter
        self.clock = clock
        self.calendar = calendar
    }

    func writeEvent(_ event: ActivityEvent) async throws {
        try await dbWriter.write { db in
            try event.save(db)
        }
    }

    func tombstoneEvent(id: UUID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var event = try ActivityEvent.fetchOne(db, key: id) else {
                return
            }
            event.deleted = true
            event.syncedAt = nil
            try event.save(db)
        }
    }

    func upsertSession(_ session: FocusSession) async throws {
        try await dbWriter.write { db in
            try session.save(db)
        }
    }

    func tombstoneSession(id: UUID, at date: Date) async throws {
        try await dbWriter.write { db in
            guard var session = try FocusSession.fetchOne(db, key: id) else {
                return
            }
            session.deletedAt = date
            try session.save(db)
        }
    }

    func fetchTodayActivity() async throws -> [ActivityEvent] {
        let now = clock.now()
        let startOfDay = calendar.startOfDay(for: now)
        guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            throw LocalStoreError.invalidDateBoundary
        }

        return try await dbWriter.read { db in
            try ActivityEvent
                .filter(Column("deleted") == false)
                .filter(Column("startedAt") >= startOfDay && Column("startedAt") < startOfNextDay)
                .order(Column("startedAt"))
                .fetchAll(db)
        }
    }

    func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
        let clampedLimit = min(max(limit, 0), Self.maxSyncBatchSize)

        return try await dbWriter.read { db in
            try ActivityEvent
                .filter(Column("syncedAt") == nil)
                .order(Column("startedAt"))
                .limit(clampedLimit)
                .fetchAll(db)
        }
    }

    func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {
        guard !ids.isEmpty else {
            return
        }

        try await dbWriter.write { db in
            _ = try ActivityEvent
                .filter(keys: ids)
                .updateAll(db, Column("syncedAt").set(to: date))
        }
    }

    func markEventsSynced(matching snapshots: [SyncedRowSnapshot], syncedAt date: Date) async throws {
        guard !snapshots.isEmpty else {
            return
        }

        try await dbWriter.write { db in
            for snapshot in snapshots {
                _ = try ActivityEvent
                    .filter(Column("eventID") == snapshot.eventID)
                    .filter(Column("deleted") == snapshot.deleted)
                    .updateAll(db, Column("syncedAt").set(to: date))
            }
        }
    }
}

enum LocalStoreError: Error {
    case invalidDateBoundary
}
