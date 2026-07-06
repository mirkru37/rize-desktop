@testable import RizeDesktop
import XCTest

/// Exercises `AuthTokenManager` against a `FakeAuthAPIClient` and an
/// in-memory `AuthTokenStorage` — no Keychain, no network — covering login,
/// single-flight refresh, failed-refresh cleanup, and logout, per
/// `documentation/security.md` §Token model and the RIZ-41 brief's token
/// handling requirements.
final class AuthTokenManagerTests: XCTestCase {
    private func makeManager(
        api: FakeAuthAPIClient,
        storage: InMemoryAuthTokenStorage = InMemoryAuthTokenStorage()
    ) -> AuthTokenManager {
        AuthTokenManager(api: api, storage: storage, deviceInfoProvider: StubDeviceInfoProvider())
    }

    private struct StubDeviceInfoProvider: DeviceInfoProviding {
        func makeDevice(existingID: UUID?) -> DeviceRequestDTO {
            DeviceRequestDTO(
                id: existingID,
                platform: "macos",
                name: "Test",
                model: "Mac",
                osVersion: "14.5",
                appVersion: "0.1.0"
            )
        }
    }

    // MARK: - Login

    func testLoginSuccessSignsInAndPersistsTokens() async throws {
        let api = FakeAuthAPIClient()
        let deviceID = UUID()
        await api.setLoginBehavior(.success(makeAuthResponse(
            accessToken: "access-1",
            refreshToken: "refresh-1",
            deviceID: deviceID
        )))
        let storage = InMemoryAuthTokenStorage()
        let manager = makeManager(api: api, storage: storage)

        let user = try await manager.login(email: "user@example.com", password: "correct-horse-battery-staple")

        XCTAssertEqual(user.email, "user@example.com")
        let isSignedIn = await manager.isSignedIn
        XCTAssertTrue(isSignedIn)
        let accessToken = await manager.currentAccessToken()
        XCTAssertEqual(accessToken, "access-1")
        let storedRefreshToken = try storage.refreshToken()
        XCTAssertEqual(storedRefreshToken, "refresh-1")
        let storedDeviceID = try storage.deviceID()
        XCTAssertEqual(storedDeviceID, deviceID)
    }

    func testLoginFailureLeavesSessionSignedOut() async throws {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.failure(TestError.network))
        let manager = makeManager(api: api)

        do {
            _ = try await manager.login(email: "user@example.com", password: "wrong")
            XCTFail("expected login to throw")
        } catch {
            // expected
        }

        let isSignedIn = await manager.isSignedIn
        XCTAssertFalse(isSignedIn)
        let accessToken = await manager.currentAccessToken()
        XCTAssertNil(accessToken)
    }

    // MARK: - Refresh

    func testRefreshAccessTokenIsSingleFlightAcrossConcurrentCallers() async throws {
        let api = FakeAuthAPIClient()
        let storage = InMemoryAuthTokenStorage()
        try storage.saveRefreshToken("refresh-1")
        await api.setRefreshBehavior(.success(makeAuthResponse(accessToken: "access-2", refreshToken: "refresh-2")))
        let manager = makeManager(api: api, storage: storage)

        // Five concurrent callers race into refreshAccessToken(); the actor
        // serializes them, and single-flight means the underlying API is
        // only ever hit once.
        let results = await withTaskGroup(of: String?.self) { group in
            for _ in 0 ..< 5 {
                group.addTask { try? await manager.refreshAccessToken() }
            }
            var collected: [String?] = []
            for await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(results, Array(repeating: "access-2", count: 5))
        let refreshCallCount = await api.refreshCallCount
        XCTAssertEqual(refreshCallCount, 1)
    }

    func testFailedRefreshClearsLocalSessionState() async throws {
        let api = FakeAuthAPIClient()
        let storage = InMemoryAuthTokenStorage()
        try storage.saveRefreshToken("refresh-1")
        await api.setRefreshBehavior(.failure(TestError.network))
        let manager = makeManager(api: api, storage: storage)

        do {
            _ = try await manager.refreshAccessToken()
            XCTFail("expected refresh to throw")
        } catch {
            // expected
        }

        let isSignedIn = await manager.isSignedIn
        XCTAssertFalse(isSignedIn)
        let storedRefreshToken = try storage.refreshToken()
        XCTAssertNil(storedRefreshToken, "a failed refresh must leave a clean signed-out state")
    }

    func testRefreshWithNoStoredRefreshTokenFailsWithoutCallingTheAPI() async throws {
        let api = FakeAuthAPIClient()
        let manager = makeManager(api: api, storage: InMemoryAuthTokenStorage())

        do {
            _ = try await manager.refreshAccessToken()
            XCTFail("expected refresh to throw")
        } catch let error as AuthError {
            XCTAssertEqual(error, .notAuthenticated)
        }

        let refreshCallCount = await api.refreshCallCount
        XCTAssertEqual(refreshCallCount, 0)
    }

    // MARK: - Logout

    func testLogoutRevokesServerSideAndClearsLocalState() async throws {
        let api = FakeAuthAPIClient()
        await api.setLoginBehavior(.success(makeAuthResponse(accessToken: "access-1", refreshToken: "refresh-1")))
        let storage = InMemoryAuthTokenStorage()
        let manager = makeManager(api: api, storage: storage)
        _ = try await manager.login(email: "user@example.com", password: "correct-horse-battery-staple")

        await manager.logout()

        let logoutCallCount = await api.logoutCallCount
        XCTAssertEqual(logoutCallCount, 1)
        let isSignedIn = await manager.isSignedIn
        XCTAssertFalse(isSignedIn)
        let storedRefreshToken = try storage.refreshToken()
        XCTAssertNil(storedRefreshToken)
    }

    func testLogoutWithNoActiveSessionIsANoOp() async {
        let api = FakeAuthAPIClient()
        let manager = makeManager(api: api)

        await manager.logout()

        let logoutCallCount = await api.logoutCallCount
        XCTAssertEqual(logoutCallCount, 0)
    }
}
