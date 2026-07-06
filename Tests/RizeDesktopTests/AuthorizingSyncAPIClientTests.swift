@testable import RizeDesktop
import XCTest

/// Exercises `AuthorizingSyncAPIClient`'s transparent 401 -> single-flight
/// refresh -> retry-once behavior against a `FakeTokenizedSyncAPIClient` and
/// a real `AuthTokenManager` (backed by a `FakeAuthAPIClient`), per the
/// RIZ-41 brief's "transparent refresh-on-401 with rotation, single-flight"
/// requirement.
final class AuthorizingSyncAPIClientTests: XCTestCase {
    private func makeAuthenticatedManager(
        authAPI: FakeAuthAPIClient,
        storage: InMemoryAuthTokenStorage = InMemoryAuthTokenStorage()
    ) async throws -> AuthTokenManager {
        await authAPI.setLoginBehavior(.success(makeAuthResponse(accessToken: "access-1", refreshToken: "refresh-1")))
        let manager = AuthTokenManager(api: authAPI, storage: storage)
        _ = try await manager.login(email: "user@example.com", password: "correct-horse-battery-staple")
        return manager
    }

    func testSuccessfulRequestUsesCurrentAccessTokenWithoutRefreshing() async throws {
        let authAPI = FakeAuthAPIClient()
        let tokenManager = try await makeAuthenticatedManager(authAPI: authAPI)
        let syncAPI = FakeTokenizedSyncAPIClient()
        await syncAPI.enqueuePush(.success([]))
        let client = AuthorizingSyncAPIClient(inner: syncAPI, tokenManager: tokenManager)

        _ = try await client.pushEvents([], deviceID: "device-1")

        let tokensUsed = await syncAPI.pushAccessTokensUsed
        XCTAssertEqual(tokensUsed, ["access-1"])
        let refreshCallCount = await authAPI.refreshCallCount
        XCTAssertEqual(refreshCallCount, 0)
    }

    func testUnauthorizedResponseTriggersOneRefreshThenRetriesWithNewToken() async throws {
        let authAPI = FakeAuthAPIClient()
        await authAPI.setRefreshBehavior(.success(makeAuthResponse(accessToken: "access-2", refreshToken: "refresh-2")))
        let tokenManager = try await makeAuthenticatedManager(authAPI: authAPI)
        let syncAPI = FakeTokenizedSyncAPIClient()
        await syncAPI.enqueuePush(.failure(APIError.unauthorized(nil)))
        await syncAPI.enqueuePush(.success([]))
        let client = AuthorizingSyncAPIClient(inner: syncAPI, tokenManager: tokenManager)

        _ = try await client.pushEvents([], deviceID: "device-1")

        let tokensUsed = await syncAPI.pushAccessTokensUsed
        XCTAssertEqual(tokensUsed, ["access-1", "access-2"])
        let refreshCallCount = await authAPI.refreshCallCount
        XCTAssertEqual(refreshCallCount, 1)
        let currentToken = await tokenManager.currentAccessToken()
        XCTAssertEqual(currentToken, "access-2")
    }

    func testConcurrentUnauthorizedRequestsShareASingleRefresh() async throws {
        let authAPI = FakeAuthAPIClient()
        await authAPI.setRefreshBehavior(.success(makeAuthResponse(accessToken: "access-2", refreshToken: "refresh-2")))
        let tokenManager = try await makeAuthenticatedManager(authAPI: authAPI)
        let syncAPI = FakeTokenizedSyncAPIClient()
        // Both concurrent calls see a 401 on their first attempt, then a
        // successful retry.
        await syncAPI.enqueuePush(.failure(APIError.unauthorized(nil)))
        await syncAPI.enqueuePush(.failure(APIError.unauthorized(nil)))
        await syncAPI.enqueuePush(.success([]))
        await syncAPI.enqueuePush(.success([]))
        let client = AuthorizingSyncAPIClient(inner: syncAPI, tokenManager: tokenManager)

        async let first = client.pushEvents([], deviceID: "device-1")
        async let second = client.pushEvents([], deviceID: "device-1")
        _ = try await (first, second)

        let refreshCallCount = await authAPI.refreshCallCount
        XCTAssertEqual(refreshCallCount, 1, "concurrent 401s must share a single refresh")
    }

    func testRefreshFailureDuringRetryPropagatesAndLeavesSignedOut() async throws {
        let authAPI = FakeAuthAPIClient()
        await authAPI.setRefreshBehavior(.failure(TestError.network))
        let tokenManager = try await makeAuthenticatedManager(authAPI: authAPI)
        let syncAPI = FakeTokenizedSyncAPIClient()
        await syncAPI.enqueuePush(.failure(APIError.unauthorized(nil)))
        let client = AuthorizingSyncAPIClient(inner: syncAPI, tokenManager: tokenManager)

        do {
            _ = try await client.pushEvents([], deviceID: "device-1")
            XCTFail("expected the request to fail")
        } catch {
            // expected: refresh itself failed
        }

        let isSignedIn = await tokenManager.isSignedIn
        XCTAssertFalse(isSignedIn, "a failed refresh must leave a clean signed-out state")
    }
}
