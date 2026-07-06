import Foundation

/// Supplies the backend's base URL, per the RIZ-41 brief's "base URL
/// configurable (UserDefaults seam, default localhost dev)" requirement.
protocol BaseURLProvider: Sendable {
    func baseURL() -> URL
}

/// A minimal seam over `Bundle.infoDictionary` lookups, so tests can supply
/// fake Info.plist values without needing a real bundle on disk.
protocol InfoDictionaryProviding {
    func object(forInfoDictionaryKey key: String) -> Any?
}

extension Bundle: InfoDictionaryProviding {}

/// Resolves the base URL from whichever of this app's configuration seams is
/// populated, in priority order:
///
/// 1. A `UserDefaults` override (key `"apiBaseURL"`) — lets QA/internal
///    builds point at a staging backend without a rebuild.
/// 2. An Info.plist key (`RIZE_BACKEND_BASE_URL`), which `project.yml`'s
///    `configFiles` populates from `Config.example.xcconfig` (or a
///    gitignored `Config.local.xcconfig` override) per build configuration.
/// 3. A hardcoded localhost development default, used when the plist key is
///    absent (e.g. an SPM/unit-test host bundle with no Info.plist wiring)
///    or holds a malformed/hostless value (guards against a mis-escaped
///    xcconfig entry silently truncating the URL — see `Config.example.xcconfig`).
struct UserDefaultsBaseURLProvider: BaseURLProvider {
    static let defaultsKey = "apiBaseURL"
    static let infoPlistKey = "RIZE_BACKEND_BASE_URL"
    static let defaultURL: URL = {
        guard let url = URL(string: "http://localhost:8080/v1") else {
            fatalError("Invalid hardcoded default API base URL")
        }
        return url
    }()

    /// `UserDefaults` isn't yet marked `Sendable` by the SDK despite being
    /// thread-safe; safe to silence under Swift 6 mode.
    private nonisolated(unsafe) let defaults: UserDefaults
    /// Test doubles conforming to `InfoDictionaryProviding` aren't
    /// guaranteed `Sendable`; safe to silence since this value is only read.
    private nonisolated(unsafe) let infoDictionaryProvider: InfoDictionaryProviding

    init(defaults: UserDefaults = .standard, bundle: InfoDictionaryProviding = Bundle.main) {
        self.defaults = defaults
        infoDictionaryProvider = bundle
    }

    func baseURL() -> URL {
        if let stored = defaults.string(forKey: Self.defaultsKey), let url = URL(string: stored), url.host != nil {
            return url
        }

        let plistValue = infoDictionaryProvider.object(forInfoDictionaryKey: Self.infoPlistKey) as? String
        if let configured = plistValue, let url = URL(string: configured), url.host != nil {
            return url
        }

        return Self.defaultURL
    }
}
