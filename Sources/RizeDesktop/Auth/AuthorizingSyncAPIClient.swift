import Foundation

/// Adapts a token-taking `TokenizedSyncAPIClient` into the token-free
/// `SyncAPIClient` interface `SyncEngine` depends on: it attaches the
/// current access token, and on a `401` transparently refreshes (via
/// `AuthTokenManager`'s single-flight `refreshAccessToken()`) and retries
/// the request exactly once before giving up.
///
/// If there is no session at all, or the refresh itself fails, the
/// underlying `AuthError`/`APIError` propagates — `AuthTokenManager` has
/// already cleared local session state by that point, so the caller is left
/// in a clean signed-out state rather than a half-authenticated one.
actor AuthorizingSyncAPIClient: SyncAPIClient {
    private let inner: TokenizedSyncAPIClient
    private let tokenManager: AuthTokenManager

    init(inner: TokenizedSyncAPIClient, tokenManager: AuthTokenManager) {
        self.inner = inner
        self.tokenManager = tokenManager
    }

    func pushEvents(_ items: [SyncPushItemDTO], deviceID: String) async throws -> [SyncPushResultDTO] {
        try await withAuthorizedRetry { token in
            try await self.inner.pushEvents(items, deviceID: deviceID, accessToken: token)
        }
    }

    func fetchChanges(cursor: String?, limit: Int) async throws -> SyncChangesResponseDTO {
        try await withAuthorizedRetry { token in
            try await self.inner.fetchChanges(cursor: cursor, limit: limit, accessToken: token)
        }
    }

    /// Runs `operation` with the current (or freshly refreshed) access
    /// token; on `APIError.unauthorized`, refreshes once (single-flight, via
    /// `AuthTokenManager`) and retries `operation` exactly once with the new
    /// token.
    private func withAuthorizedRetry<Response: Sendable>(
        _ operation: @Sendable (String) async throws -> Response
    ) async throws -> Response {
        let token = try await currentOrRefreshedToken()
        do {
            return try await operation(token)
        } catch APIError.unauthorized(_) {
            let refreshedToken = try await tokenManager.refreshAccessToken()
            return try await operation(refreshedToken)
        }
    }

    private func currentOrRefreshedToken() async throws -> String {
        if let token = await tokenManager.currentAccessToken() {
            return token
        }
        return try await tokenManager.refreshAccessToken()
    }
}
