import Foundation

/// Persists the opaque `next_cursor` from `GET /v1/sync/changes`
/// (`documentation/sync-protocol.md` §Pull) across launches. The cursor is
/// not secret, so `UserDefaults` (rather than Keychain) is the appropriate
/// store for it.
protocol SyncCursorStore: Sendable {
    func currentCursor() -> String?
    func save(_ cursor: String) throws
}

struct UserDefaultsSyncCursorStore: SyncCursorStore {
    private static let key = "syncCursor"
    /// `UserDefaults` isn't yet marked `Sendable` by the SDK despite being
    /// thread-safe; safe to silence under Swift 6 mode.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func currentCursor() -> String? {
        defaults.string(forKey: Self.key)
    }

    func save(_ cursor: String) throws {
        defaults.set(cursor, forKey: Self.key)
    }
}
