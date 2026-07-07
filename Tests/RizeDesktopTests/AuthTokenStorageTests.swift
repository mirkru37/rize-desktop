@testable import RizeDesktop
import XCTest

/// Exercises `KeychainAuthTokenStorage`'s key-mapping logic against an
/// `InMemorySecureStore` fake (the real Keychain is exercised separately by
/// `SecureStoreTests`), per `documentation/security.md` §Client-side token
/// storage.
final class AuthTokenStorageTests: XCTestCase {
    private func makeStorage() -> (KeychainAuthTokenStorage, InMemorySecureStore) {
        let secureStore = InMemorySecureStore()
        return (KeychainAuthTokenStorage(secureStore: secureStore), secureStore)
    }

    func testRefreshTokenIsNilBeforeAnyIsSaved() throws {
        let (storage, _) = makeStorage()

        XCTAssertNil(try storage.refreshToken())
    }

    func testSaveThenReadRefreshTokenRoundTrips() throws {
        let (storage, _) = makeStorage()

        try storage.saveRefreshToken("refresh-token-1")

        XCTAssertEqual(try storage.refreshToken(), "refresh-token-1")
    }

    func testClearRefreshTokenRemovesIt() throws {
        let (storage, _) = makeStorage()
        try storage.saveRefreshToken("refresh-token-1")

        try storage.clearRefreshToken()

        XCTAssertNil(try storage.refreshToken())
    }

    func testDeviceIDIsNilBeforeAnyIsSaved() throws {
        let (storage, _) = makeStorage()

        XCTAssertNil(try storage.deviceID())
    }

    func testSaveThenReadDeviceIDRoundTrips() throws {
        let (storage, _) = makeStorage()
        let deviceID = UUID()

        try storage.saveDeviceID(deviceID)

        XCTAssertEqual(try storage.deviceID(), deviceID)
    }

    func testDeviceIDWithMalformedStoredValueReturnsNil() throws {
        let (storage, secureStore) = makeStorage()
        try secureStore.write("not-a-uuid", for: "deviceID")

        XCTAssertNil(try storage.deviceID())
    }

    func testRefreshTokenAndDeviceIDAreStoredUnderIndependentKeys() throws {
        let (storage, _) = makeStorage()
        let deviceID = UUID()

        try storage.saveRefreshToken("refresh-token-1")
        try storage.saveDeviceID(deviceID)

        XCTAssertEqual(try storage.refreshToken(), "refresh-token-1")
        XCTAssertEqual(try storage.deviceID(), deviceID)
    }
}
