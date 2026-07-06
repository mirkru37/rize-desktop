import Foundation

/// The authenticated user, as much of it as the client keeps around.
struct AuthenticatedUser: Equatable {
    var id: String
    var email: String
    var role: String
}

enum AuthError: Error, Equatable {
    /// No refresh token / session is available to authenticate or refresh
    /// with; the caller should present the sign-in UI.
    case notAuthenticated
}

/// Owns the client's auth session: the access token (in memory only) and,
/// via `AuthTokenStorage`, the refresh token and stable device id (Keychain).
///
/// An `actor` so every state read/mutation is serialized — this is what
/// makes `refreshAccessToken()` single-flight for free: concurrent callers
/// racing into the actor simply queue behind whichever one is already
/// running `performRefresh()`, per
/// `documentation/security.md` §Refresh-token rotation flow and the RIZ-41
/// brief's "concurrent 401s -> one refresh, others await" requirement.
actor AuthTokenManager {
    private let api: AuthAPIClient
    private let storage: AuthTokenStorage
    private let deviceInfoProvider: DeviceInfoProviding

    private var accessToken: String?
    private var currentUser: AuthenticatedUser?
    private var inFlightRefresh: Task<String, Error>?

    init(
        api: AuthAPIClient,
        storage: AuthTokenStorage,
        deviceInfoProvider: DeviceInfoProviding = SystemDeviceInfoProvider()
    ) {
        self.api = api
        self.storage = storage
        self.deviceInfoProvider = deviceInfoProvider
    }

    var isSignedIn: Bool {
        accessToken != nil
    }

    var user: AuthenticatedUser? {
        currentUser
    }

    func currentAccessToken() -> String? {
        accessToken
    }

    /// The stable per-install device id, if the device has ever completed
    /// registration. Used by the sync push request's top-level `device_id`.
    func persistedDeviceID() -> UUID? {
        try? storage.deviceID()
    }

    @discardableResult
    func register(email: String, password: String) async throws -> AuthenticatedUser {
        let device = deviceInfoProvider.makeDevice(existingID: try? storage.deviceID())
        let response = try await api.register(email: email, password: password, device: device)
        return try apply(response)
    }

    @discardableResult
    func login(email: String, password: String) async throws -> AuthenticatedUser {
        let device = deviceInfoProvider.makeDevice(existingID: try? storage.deviceID())
        let response = try await api.login(email: email, password: password, device: device)
        return try apply(response)
    }

    func logout() async {
        defer { clearLocalState() }
        guard let accessToken, let refreshToken = try? storage.refreshToken() else {
            return
        }
        try? await api.logout(refreshToken: refreshToken, accessToken: accessToken)
    }

    /// Returns a valid access token, refreshing it first if necessary.
    /// Single-flight: a refresh already in progress is awaited rather than
    /// duplicated. A failed refresh clears all local session state (clean
    /// signed-out state) and rethrows.
    @discardableResult
    func refreshAccessToken() async throws -> String {
        if let inFlightRefresh {
            return try await inFlightRefresh.value
        }

        let task = Task { try await self.performRefresh() }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    private func performRefresh() async throws -> String {
        guard let refreshToken = try? storage.refreshToken() else {
            clearLocalState()
            throw AuthError.notAuthenticated
        }

        do {
            let response = try await api.refresh(refreshToken: refreshToken, device: nil)
            _ = try apply(response)
            return response.accessToken
        } catch {
            clearLocalState()
            throw error
        }
    }

    @discardableResult
    private func apply(_ response: AuthResponseDTO) throws -> AuthenticatedUser {
        let user = AuthenticatedUser(id: response.user.id, email: response.user.email, role: response.user.role)
        try storage.saveRefreshToken(response.refreshToken)
        try storage.saveDeviceID(response.device.id)
        accessToken = response.accessToken
        currentUser = user
        return user
    }

    private func clearLocalState() {
        accessToken = nil
        currentUser = nil
        try? storage.clearRefreshToken()
    }
}
