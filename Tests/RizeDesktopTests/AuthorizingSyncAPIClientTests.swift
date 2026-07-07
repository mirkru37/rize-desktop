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

    /// Regression coverage for two flaky earlier versions of this test.
    ///
    /// v1 gated only the two initial `pushEvents` attempts (so both observe
    /// their 401 "together") and hoped they'd race into
    /// `AuthTokenManager.refreshAccessToken()` closely enough to overlap —
    /// insufficient, because the return trip crosses two more actor hops
    /// whose relative scheduling order Swift concurrency does not guarantee.
    ///
    /// v2 staged the push-gate releases one at a time and held the winning
    /// refresh open behind a gate until *after* releasing the second call —
    /// but still opened both gates back-to-back without ever confirming the
    /// second call had actually reached the `refreshAccessToken()` check.
    /// The winner's refresh (and its `defer { inFlightRefresh = nil }`) can
    /// complete before the second caller's actor-hop gets there, at which
    /// point a second refresh is legitimate product behavior — the count is
    /// 2 not because of a product bug, but because nothing forced the join
    /// itself to be observed before releasing.
    ///
    /// This version observes the join directly via
    /// `AuthTokenManager.setRefreshJoinProbe`, a minimal test-only hook fired
    /// exactly when a caller finds `inFlightRefresh` already set. Sequence:
    /// 1. Release only the first call from the push gate, and wait until
    ///    it's confirmed blocked *inside* the fake auth API's `refresh(...)`
    ///    (`refreshArrived`) — `inFlightRefresh` is set and cannot clear
    ///    while that gate stays closed.
    /// 2. Start the second call and release it from the push gate.
    /// 3. Wait for the join probe (`joined`) — proof the second call has
    ///    reached `refreshAccessToken()` and joined the first's task, not
    ///    merely that it's "probably" done so by now.
    /// 4. Only then open both gates and await the results.
    /// All waits are gate/probe-signaled and timeout-bounded (no sleeps, no
    /// polling).
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
        let joined = expectation(description: "the second caller joined the in-flight refresh")
        await tokenManager.setRefreshJoinProbe { joined.fulfill() }

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
        await syncAPI.releaseOneWaiter()

        // Proof the second caller has actually joined the in-flight refresh
        // — not just "probably has by now" — before letting either gate go.
        await fulfillment(of: [joined], timeout: 5)

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
