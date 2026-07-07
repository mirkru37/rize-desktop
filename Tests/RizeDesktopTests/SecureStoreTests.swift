@testable import RizeDesktop
import XCTest

/// Exercises `KeychainSecureStore` against the real macOS Keychain (the CI
/// runner's test host already touches the real Keychain once at app launch
/// via `AppDelegate.startSync`, so this is consistent with how the app
/// actually behaves) per `documentation/security.md` §Client-side token
/// storage. Every test uses a unique `service` name so runs never collide
/// with each other or with a real signed-in session's stored values, and
/// cleans up after itself in `tearDown`.
final class SecureStoreTests: XCTestCase {
    private var store: KeychainSecureStore!
    private var key: String!

    override func setUp() {
        super.setUp()
        store = KeychainSecureStore(service: "com.rizeclone.desktop.tests.\(UUID().uuidString)")
        key = "testKey"
    }

    override func tearDown() {
        try? store.delete(key)
        store = nil
        key = nil
        super.tearDown()
    }

    func testReadOfMissingKeyReturnsNil() throws {
        let value = try store.read(key)

        XCTAssertNil(value)
    }

    func testWriteThenReadRoundTripsTheValue() throws {
        try store.write("secret-value", for: key)

        let value = try store.read(key)

        XCTAssertEqual(value, "secret-value")
    }

    func testWriteTwiceUpdatesTheExistingItemRatherThanDuplicating() throws {
        try store.write("first-value", for: key)
        try store.write("second-value", for: key)

        let value = try store.read(key)

        XCTAssertEqual(value, "second-value")
    }

    func testDeleteRemovesTheValue() throws {
        try store.write("secret-value", for: key)

        try store.delete(key)

        let value = try store.read(key)
        XCTAssertNil(value)
    }

    func testDeleteOfMissingKeyDoesNotThrow() throws {
        try store.delete(key)
    }

    func testDistinctKeysDoNotCollide() throws {
        try store.write("value-a", for: "keyA")
        try store.write("value-b", for: "keyB")

        XCTAssertEqual(try store.read("keyA"), "value-a")
        XCTAssertEqual(try store.read("keyB"), "value-b")

        try store.delete("keyA")
        try store.delete("keyB")
    }
}
