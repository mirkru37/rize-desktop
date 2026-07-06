import Foundation
import GRDB

/// Versioned, forward-only schema migrations for the local event store,
/// mirroring the migration policy described for the server schema in
/// `documentation/database-schema.md` §Migration Policy: every change ships
/// as a new named migration rather than editing a previous one.
enum DatabaseMigrations {
    /// Builds the migrator with every registered migration, in order.
    /// Applying it against a fresh or partially-migrated database queue
    /// brings it up to the current schema version.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        registerV1ActivityEvents(&migrator)
        registerV2FocusSessions(&migrator)

        return migrator
    }

    /// v1: creates the `activity_events` table and its supporting indexes.
    private static func registerV1ActivityEvents(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_create_activity_events") { db in
            try db.create(table: ActivityEvent.databaseTableName) { table in
                table.column("eventID", .text).primaryKey()
                table.column("deviceID", .text)
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime).notNull()
                table.column("type", .text).notNull()
                table.column("source", .text).notNull()
                table.column("precision", .text).notNull().defaults(to: "exact")
                table.column("appBundleID", .text)
                table.column("windowTitle", .text)
                table.column("url", .text)
                table.column("categoryID", .text)
                table.column("projectID", .text)
                table.column("deleted", .boolean).notNull().defaults(to: false)
                table.column("insertedAt", .datetime).notNull()
                table.column("syncedAt", .datetime)
            }

            try db.create(
                index: "idx_activity_events_startedAt",
                on: ActivityEvent.databaseTableName,
                columns: ["startedAt"]
            )
            try db.create(
                index: "idx_activity_events_syncedAt",
                on: ActivityEvent.databaseTableName,
                columns: ["syncedAt"]
            )
        }
    }

    /// v2: creates the `focus_sessions` table and its supporting indexes.
    private static func registerV2FocusSessions(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_create_focus_sessions") { db in
            try db.create(table: FocusSession.databaseTableName) { table in
                table.column("id", .text).primaryKey()
                table.column("deviceID", .text)
                table.column("projectID", .text)
                table.column("kind", .text).notNull()
                table.column("plannedDurationS", .integer)
                table.column("startedAt", .datetime).notNull()
                table.column("endedAt", .datetime)
                table.column("status", .text).notNull()
                table.column("note", .text)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("deletedAt", .datetime)
                table.column("pendingSync", .boolean).notNull().defaults(to: true)
            }

            try db.create(
                index: "idx_focus_sessions_updatedAt",
                on: FocusSession.databaseTableName,
                columns: ["updatedAt"]
            )
            try db.create(
                index: "idx_focus_sessions_pendingSync",
                on: FocusSession.databaseTableName,
                columns: ["pendingSync"]
            )
        }
    }
}
