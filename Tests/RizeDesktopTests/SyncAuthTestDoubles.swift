import Foundation
@testable import RizeDesktop

// Shared test doubles for the RIZ-41 auth/sync suite
// (`AuthTokenManagerTests`, `AuthorizingSyncAPIClientTests`,
// `SyncEngineTests`, `SyncCoordinatorTests`). Kept in one file, unlike the
// per-file-private fakes elsewhere in this target, because these four test
// files all need the same handful of network/token/timing seams.

enum TestError: Error, Equatable {
    case unconfigured
    case network
}

func makeAuthResponse(
    accessToken: String = "access-token-1",
    refreshToken: String = "refresh-token-1",
    deviceID: UUID = UUID()
) -> AuthResponseDTO {
    AuthResponseDTO(
        accessToken: accessToken,
        refreshToken: refreshToken,
        tokenType: "Bearer",
        expiresIn: 900,
        user: UserDTO(id: "usr_1", email: "user@example.com", role: "user"),
        device: DeviceResponseDTO(
            id: deviceID,
            platform: "macos",
            name: "Test Mac",
            model: "Mac15,3",
            osVersion: "14.5",
            appVersion: "0.1.0"
        )
    )
}

// MARK: - Auth

/// Shared `DeviceInfoProviding` stub returning a fixed device shape,
/// used everywhere a test needs an `AuthTokenManager` but doesn't care about
/// device-info details (kept here rather than duplicated per test file).
struct StubDeviceInfoProvider: DeviceInfoProviding {
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

/// Builds an `AuthTokenManager` wired to `StubDeviceInfoProvider`, shared by
/// every test file that needs a real `AuthTokenManager` over fakes
/// (`AuthTokenManagerTests`, `AuthSessionViewModelTests`, and the
/// sync-coordinator/engine suites that only need one to satisfy
/// `AuthorizingSyncAPIClient`'s initializer).
func makeAuthTokenManager(
    api: AuthAPIClient = FakeAuthAPIClient(),
    storage: AuthTokenStorage = InMemoryAuthTokenStorage()
) -> AuthTokenManager {
    AuthTokenManager(api: api, storage: storage, deviceInfoProvider: StubDeviceInfoProvider())
}

/// In-memory `SecureStore`, for tests exercising `KeychainAuthTokenStorage`'s
/// key-mapping logic without touching the real Keychain (the real Keychain
/// is exercised separately by `SecureStoreTests` against
/// `KeychainSecureStore` itself).
final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func read(_ key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func write(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func delete(_ key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

/// In-memory `AuthTokenStorage`. A plain lock-guarded class rather than an
/// actor because the protocol's methods are synchronous (matching
/// `KeychainSecureStore`'s synchronous Keychain calls).
final class InMemoryAuthTokenStorage: AuthTokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRefreshToken: String?
    private var storedDeviceID: UUID?

    func refreshToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedRefreshToken
    }

    func saveRefreshToken(_ token: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storedRefreshToken = token
    }

    func clearRefreshToken() throws {
        lock.lock()
        defer { lock.unlock() }
        storedRefreshToken = nil
    }

    func deviceID() throws -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return storedDeviceID
    }

    func saveDeviceID(_ id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        storedDeviceID = id
    }
}

/// Queue-free `AuthAPIClient` fake: each endpoint resolves from a single
/// configurable `Behavior`, with call counters for asserting single-flight
/// refresh behavior.
actor FakeAuthAPIClient: AuthAPIClient {
    enum Behavior {
        case success(AuthResponseDTO)
        case failure(Error)
    }

    private var loginBehavior: Behavior = .failure(TestError.unconfigured)
    private var registerBehavior: Behavior = .failure(TestError.unconfigured)
    private var refreshBehavior: Behavior = .failure(TestError.unconfigured)
    private var logoutError: Error?

    private(set) var loginCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var logoutCallCount = 0

    /// Optional rendezvous gate for tests asserting single-flight refresh
    /// behavior: with it armed, `refresh(...)` suspends after being called
    /// (i.e. after `AuthTokenManager` has already set its in-flight refresh
    /// task) until the test explicitly releases it via `openRefreshGate()`.
    /// This lets a test hold a winning refresh open for as long as needed to
    /// deterministically prove a second caller joins it, instead of racing
    /// scheduler timing (same technique as `FakeTokenizedSyncAPIClient`'s
    /// push gate).
    private var isRefreshGateArmed = false
    private var refreshGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var onRefreshGateArrival: (@Sendable () -> Void)?

    func setLoginBehavior(_ behavior: Behavior) {
        loginBehavior = behavior
    }

    func setRegisterBehavior(_ behavior: Behavior) {
        registerBehavior = behavior
    }

    func setRefreshBehavior(_ behavior: Behavior) {
        refreshBehavior = behavior
    }

    func setLogoutError(_ error: Error?) {
        logoutError = error
    }

    /// Arms the refresh gate: the next `refresh(...)` call suspends at entry
    /// until `openRefreshGate()` releases it. `handler` fires the instant the
    /// call arrives, before it suspends.
    func armRefreshGate(onArrival handler: @escaping @Sendable () -> Void) {
        isRefreshGateArmed = true
        onRefreshGateArrival = handler
    }

    /// Releases any `refresh(...)` call currently suspended at the gate, and
    /// disarms it so future calls proceed without suspending.
    func openRefreshGate() {
        isRefreshGateArmed = false
        let waiters = refreshGateWaiters
        refreshGateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitAtRefreshGateIfArmed() async {
        guard isRefreshGateArmed else { return }
        onRefreshGateArrival?()
        await withCheckedContinuation { continuation in
            refreshGateWaiters.append(continuation)
        }
    }

    func register(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO {
        try resolve(registerBehavior)
    }

    func login(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO {
        loginCallCount += 1
        return try resolve(loginBehavior)
    }

    func refresh(refreshToken: String, device: DeviceRequestDTO?) async throws -> AuthResponseDTO {
        refreshCallCount += 1
        await waitAtRefreshGateIfArmed()
        return try resolve(refreshBehavior)
    }

    func logout(refreshToken: String, accessToken: String) async throws {
        logoutCallCount += 1
        if let logoutError {
            throw logoutError
        }
    }

    private func resolve(_ behavior: Behavior) throws -> AuthResponseDTO {
        switch behavior {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        }
    }
}

// Sync-layer and timing test doubles live in
// `SyncAuthTestDoubles+Sync.swift` (split out to keep this file under the
// SwiftLint `file_length` gate).
