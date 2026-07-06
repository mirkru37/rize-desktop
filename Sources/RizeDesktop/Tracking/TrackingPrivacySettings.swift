import Foundation

/// User-configurable capture controls that gate what the `TrackingEngine`
/// records, independent of the OS-level permissions in
/// `documentation/architecture-desktop.md` §Permissions & Entitlements.
///
/// See `documentation/architecture-desktop.md` §Privacy Controls. The
/// Settings UI for editing these is a later epic; this type is the contract
/// the Tracking Engine consumes today, and that Settings will eventually
/// mutate via `TrackingEngine.updatePrivacySettings(_:)`.
struct TrackingPrivacySettings: Equatable {
    /// Bundle identifiers excluded from tracking entirely: no
    /// `activity_events` rows are produced while one of these is frontmost.
    var excludedBundleIDs: Set<String>
    /// When `false`, only app-level (not window-level) activity is
    /// recorded, regardless of what the Window Inspector can otherwise
    /// resolve.
    var captureWindowTitles: Bool
    /// Case-insensitive substrings that mark a window title as belonging to
    /// a private/incognito browser window; matching titles are dropped
    /// rather than stored.
    var privateTitleMarkers: [String]

    static let defaultSettings = TrackingPrivacySettings(
        excludedBundleIDs: [],
        captureWindowTitles: true,
        privateTitleMarkers: ["private browsing", "incognito"]
    )

    func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    func isPrivateTitle(_ title: String) -> Bool {
        let lowercasedTitle = title.lowercased()
        return privateTitleMarkers.contains { lowercasedTitle.contains($0) }
    }
}
