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

    /// Regression coverage for a flaky earlier version of this test: gating
    /// only the two initial `pushEvents` attempts (so both observe their 401
    /// "together") is not enough to deterministically prove single-flight,
    /// because the return trip from that 401 into
    /// `AuthTokenManager.refreshAccessToken()` crosses two more actor hops
    /// (`AuthorizingSyncAPIClient` and then `AuthTokenManager` itself) whose
    /// relative scheduling order Swift concurrency does not guarantee. On an
    /// unlucky scheduling the first caller's whole 401->refresh->retry cycle
    /// can complete — clearing `inFlightRefresh` — before the second caller
    /// even reaches the `refreshAccessToken()` check, so it legitimately
    /// starts its own refresh and the assertion flakes (2 refreshes instead
    /// of 1).
    ///
    /// This version removes that race entirely by staging the two calls
    /// through explicit, one-at-a-time gate releases instead of releasing
    /// them together and hoping they interleave favorably:
    /// 1. Release only the first call from the push gate, and wait
    ///    (`refreshArrived`) until it is confirmed blocked *inside* the
    ///    fake auth API's `refresh(...)` — i.e. `AuthTokenManager` has
    ///    already set `inFlightRefresh` and cannot clear it until the test
    ///    opens that gate.
    /// 2. Only then release the second call. Because the first call's
    ///    refresh is provably still pending, the second call is guaranteed —
    ///    not merely likely — to observe `inFlightRefresh` set and join it
    ///    rather than starting a second refresh, regardless of how the
    ///    scheduler interleaves the intermediate actor hops.
    /// All waits are gate-signaled and timeout-bounded (no sleeps, no
    /// polling), per the RIZ-39 `TrackingEngineReentrancyTests` rendezvous
    /// technique this reuses.
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

        let firstArrived = expectation(description: "first pushEvents call arrived at the gate")
        let secondArrived = expectation(description: "second pushEvents call arrived at the gate")
        await syncAPI.armGate { count in
            if count == 1 { firstArrived.fulfill() }
            if count == 2 { secondArrived.fulfill() }
        }
        let refreshArrived = expectation(description: "the winning refresh call reached its gate")
        await authAPI.armRefreshGate { refreshArrived.fulfill() }

        let client = AuthorizingSyncAPIClient(inner: syncAPI, tokenManager: tokenManager)

        async let first = client.pushEvents([], deviceID: "device-1")
        await fulfillment(of: [firstArrived], timeout: 5)
        await syncAPI.releaseOneWaiter()

        // The first call is now guaranteed to be blocked inside the single
        // winning `refresh(...)` call: `inFlightRefresh` is set and cannot
        // be cleared until `openRefreshGate()` is called below.
        await fulfillment(of: [refreshArrived], timeout: 5)

        async let second = client.pushEvents([], deviceID: "device-1")
        await fulfillment(of: [secondArrived], timeout: 5)
        await syncAPI.openGate()
        await authAPI.openRefreshGate()

        _ = try await (first, second)

        let refreshCallCount = await authAPI.refreshCallCount
        XCTAssertEqual(refreshCallCount, 1, "concurrent 401s must share a single refresh")
    }

    func testFetchChangesUsesCurrentAccessTokenWithoutRefreshing() async throws {
        let authAPI = FakeAuthAPIClient()
        let tokenManager = try await makeAuthenticatedManager(authAPI: authAPI)
        let syncAPI = FakeTokenizedSyncAPIClient()
        let client = AuthorizingSyncAPIClient(inner: syncAPI, tokenManager: tokenManager)

        let response = try await client.fetchChanges(cursor: "cursor-1", limit: 200)

        XCTAssertEqual(response.nextCursor, "cursor-1")
        XCTAssertFalse(response.hasMore)
        let refreshCallCount = await authAPI.refreshCallCount
        XCTAssertEqual(refreshCallCount, 0)
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
