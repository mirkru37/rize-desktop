import Foundation

/// Supplies the backend's base URL, per the RIZ-41 brief's "base URL
/// configurable (UserDefaults seam, default localhost dev)" requirement.
protocol BaseURLProvider: Sendable {
    func baseURL() -> URL
}

/// Reads the base URL from `UserDefaults` (key `"apiBaseURL"`), falling back
/// to a localhost development default when unset or invalid.
struct UserDefaultsBaseURLProvider: BaseURLProvider {
    static let defaultsKey = "apiBaseURL"
    static let defaultURL: URL = {
        guard let url = URL(string: "http://localhost:8080/v1") else {
            fatalError("Invalid hardcoded default API base URL")
        }
        return url
    }()

    /// `UserDefaults` isn't yet marked `Sendable` by the SDK despite being
    /// thread-safe; safe to silence under Swift 6 mode.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func baseURL() -> URL {
        guard
            let stored = defaults.string(forKey: Self.defaultsKey),
            let url = URL(string: stored)
        else {
            return Self.defaultURL
        }
        return url
    }
}
