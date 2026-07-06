import Foundation

/// The durably-persisted half of the client's auth/device identity: the
/// refresh token and the stable per-install device id, both in Keychain per
/// `documentation/security.md` §Client-side token storage. The access token
/// is deliberately not part of this protocol — it lives only in memory in
/// `AuthTokenManager`, never persisted.
protocol AuthTokenStorage: Sendable {
    func refreshToken() throws -> String?
    func saveRefreshToken(_ token: String) throws
    func clearRefreshToken() throws

    /// The stable device id for this install, or `nil` if the device has
    /// never completed registration with the backend.
    func deviceID() throws -> UUID?
    func saveDeviceID(_ id: UUID) throws
}

/// `SecureStore`-backed (Keychain in production) implementation.
struct KeychainAuthTokenStorage: AuthTokenStorage {
    private static let refreshTokenKey = "refreshToken"
    private static let deviceIDKey = "deviceID"

    private let secureStore: SecureStore

    init(secureStore: SecureStore = KeychainSecureStore()) {
        self.secureStore = secureStore
    }

    func refreshToken() throws -> String? {
        try secureStore.read(Self.refreshTokenKey)
    }

    func saveRefreshToken(_ token: String) throws {
        try secureStore.write(token, for: Self.refreshTokenKey)
    }

    func clearRefreshToken() throws {
        try secureStore.delete(Self.refreshTokenKey)
    }

    func deviceID() throws -> UUID? {
        guard let raw = try secureStore.read(Self.deviceIDKey) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    func saveDeviceID(_ id: UUID) throws {
        try secureStore.write(id.uuidString, for: Self.deviceIDKey)
    }
}
