import Foundation
import GRDB

/// Opens the on-disk local database and applies migrations. UI and sync
/// code should not use this type directly — depend on `LocalStore` instead
/// and obtain an instance via `DatabaseManager.makeLocalStore()`.
enum DatabaseManager {
    /// Opens (creating if necessary) the app's SQLite database under
    /// Application Support, migrates it to the current schema, and wraps it
    /// in a `GRDBLocalStore`.
    static func makeLocalStore() throws -> LocalStore {
        let dbPool = try openDatabasePool()
        try DatabaseMigrations.makeMigrator().migrate(dbPool)
        return GRDBLocalStore(dbWriter: dbPool)
    }

    private static func openDatabasePool() throws -> DatabasePool {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("RizeClone", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let databaseURL = directory.appendingPathComponent("rize.sqlite")
        return try DatabasePool(path: databaseURL.path)
    }
}
