@testable import RizeDesktop
import XCTest

/// Exercises `UserDefaultsBaseURLProvider`'s three-tier precedence
/// (`UserDefaults` override > Info.plist `RIZE_BACKEND_BASE_URL` from
/// `Config.example.xcconfig` > hardcoded localhost fallback), per the
/// RIZ-55 brief.
final class BaseURLProviderTests: XCTestCase {
    /// An `InfoDictionaryProviding` stand-in that reports fixed values
    /// without needing a real bundle with an `Info.plist` on disk.
    private struct StubInfoDictionaryProvider: InfoDictionaryProviding {
        let values: [String: Any]

        func object(forInfoDictionaryKey key: String) -> Any? {
            values[key]
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "BaseURLProviderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return defaults
    }

    func testFallsBackToHardcodedDefaultWhenPlistKeyAbsent() {
        let defaults = makeDefaults()
        let bundle = StubInfoDictionaryProvider(values: [:])
        let provider = UserDefaultsBaseURLProvider(defaults: defaults, bundle: bundle)

        XCTAssertEqual(provider.baseURL(), UserDefaultsBaseURLProvider.defaultURL)
    }

    func testUsesInfoPlistValueWhenNoUserDefaultsOverride() {
        let defaults = makeDefaults()
        let bundle = StubInfoDictionaryProvider(values: [
            UserDefaultsBaseURLProvider.infoPlistKey: "https://staging.rize-clone.example/v1"
        ])
        let provider = UserDefaultsBaseURLProvider(defaults: defaults, bundle: bundle)

        XCTAssertEqual(provider.baseURL(), URL(string: "https://staging.rize-clone.example/v1"))
    }

    func testUserDefaultsOverrideWinsOverInfoPlistValue() {
        let defaults = makeDefaults()
        defaults.set("https://override.rize-clone.example/v1", forKey: UserDefaultsBaseURLProvider.defaultsKey)
        let bundle = StubInfoDictionaryProvider(values: [
            UserDefaultsBaseURLProvider.infoPlistKey: "https://staging.rize-clone.example/v1"
        ])
        let provider = UserDefaultsBaseURLProvider(defaults: defaults, bundle: bundle)

        XCTAssertEqual(provider.baseURL(), URL(string: "https://override.rize-clone.example/v1"))
    }

    func testFallsBackToDefaultWhenInfoPlistValueIsHostless() {
        // Guards against a mis-escaped xcconfig entry (e.g. an unescaped
        // `//` truncating the value to `http:`), which would otherwise
        // resolve to a valid-but-hostless URL instead of failing loudly.
        let defaults = makeDefaults()
        let bundle = StubInfoDictionaryProvider(values: [
            UserDefaultsBaseURLProvider.infoPlistKey: "http:"
        ])
        let provider = UserDefaultsBaseURLProvider(defaults: defaults, bundle: bundle)

        XCTAssertEqual(provider.baseURL(), UserDefaultsBaseURLProvider.defaultURL)
    }
}
