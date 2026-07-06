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

    func register(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO {
        try resolve(registerBehavior)
    }

    func login(email: String, password: String, device: DeviceRequestDTO) async throws -> AuthResponseDTO {
        loginCallCount += 1
        return try resolve(loginBehavior)
    }

    func refresh(refreshToken: String, device: DeviceRequestDTO?) async throws -> AuthResponseDTO {
        refreshCallCount += 1
        // A single `Task.yield()` (not a wall-clock wait) widens the window
        // in which concurrent `refreshAccessToken()` callers can observe an
        // in-flight refresh, without making the test depend on real time.
        await Task.yield()
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

// MARK: - Sync

/// Queue-based `SyncAPIClient` fake (the token-free protocol `SyncEngine`
/// depends on).
actor FakeSyncAPIClient: SyncAPIClient {
    enum PushOutcome {
        case success([SyncPushResultDTO])
        case failure(Error)
    }

    enum FetchOutcome {
        case success(SyncChangesResponseDTO)
        case failure(Error)
    }

    private var pushOutcomes: [PushOutcome] = []
    private var fetchOutcomes: [FetchOutcome] = []

    private(set) var pushedBatches: [[SyncPushItemDTO]] = []
    private(set) var fetchedCursors: [String?] = []

    func enqueuePush(_ outcome: PushOutcome) {
        pushOutcomes.append(outcome)
    }

    func enqueueFetch(_ outcome: FetchOutcome) {
        fetchOutcomes.append(outcome)
    }

    func pushEvents(_ items: [SyncPushItemDTO], deviceID: String) async throws -> [SyncPushResultDTO] {
        pushedBatches.append(items)
        guard !pushOutcomes.isEmpty else {
            return items.enumerated().map { index, item in
                SyncPushResultDTO(
                    index: index,
                    entityType: item.entityType,
                    eventID: item.data.eventID.uuidString,
                    id: nil,
                    status: .applied,
                    serverSeq: nil,
                    error: nil
                )
            }
        }
        switch pushOutcomes.removeFirst() {
        case let .success(results):
            return results
        case let .failure(error):
            throw error
        }
    }

    func fetchChanges(cursor: String?, limit: Int) async throws -> SyncChangesResponseDTO {
        fetchedCursors.append(cursor)
        guard !fetchOutcomes.isEmpty else {
            return SyncChangesResponseDTO(
                changes: SyncChangesDTO(activityEvents: nil, focusSessions: nil),
                nextCursor: cursor ?? "",
                hasMore: false
            )
        }
        switch fetchOutcomes.removeFirst() {
        case let .success(response):
            return response
        case let .failure(error):
            throw error
        }
    }
}

/// Queue-based `TokenizedSyncAPIClient` fake, for testing
/// `AuthorizingSyncAPIClient`'s attach/refresh/retry logic directly against
/// the token-taking interface.
actor FakeTokenizedSyncAPIClient: TokenizedSyncAPIClient {
    enum Outcome {
        case success([SyncPushResultDTO])
        case failure(Error)
    }

    private var pushOutcomes: [Outcome] = []
    private(set) var pushAccessTokensUsed: [String] = []

    /// Optional rendezvous gate for tests that need to force genuine
    /// concurrency between two `pushEvents` calls (e.g. asserting
    /// single-flight refresh behavior): with a fast fake transport and no
    /// gate, one call's whole 401->refresh->retry cycle can complete before
    /// the other's first attempt is even issued, leaving nothing concurrent
    /// to observe. Disabled (pass-through) unless armed via `armGate`, same
    /// gate technique as `TrackingEngineReentrancyTests`'s
    /// `SuspendableLocalStore` (RIZ-39).
    private var isGateArmed = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var onGateArrival: (@Sendable (Int) -> Void)?
    private var gateArrivalCount = 0

    func enqueuePush(_ outcome: Outcome) {
        pushOutcomes.append(outcome)
    }

    /// Arms the gate: subsequent `pushEvents` calls suspend at entry until
    /// `openGate()` releases them all. `handler` is invoked (with the
    /// running arrival count) every time a call reaches the gate, so tests
    /// can wait for a specific number of arrivals via a bounded
    /// `fulfillment(of:timeout:)` before opening it.
    func armGate(onArrival handler: @escaping @Sendable (Int) -> Void) {
        isGateArmed = true
        onGateArrival = handler
    }

    /// Releases every `pushEvents` call currently suspended at the gate,
    /// and lets all future calls proceed without suspending.
    func openGate() {
        isGateArmed = false
        let waiters = gateWaiters
        gateWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitAtGateIfArmed() async {
        guard isGateArmed else { return }
        gateArrivalCount += 1
        onGateArrival?(gateArrivalCount)
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }

    func pushEvents(
        _ items: [SyncPushItemDTO],
        deviceID: String,
        accessToken: String
    ) async throws -> [SyncPushResultDTO] {
        await waitAtGateIfArmed()
        pushAccessTokensUsed.append(accessToken)
        guard !pushOutcomes.isEmpty else {
            return []
        }
        switch pushOutcomes.removeFirst() {
        case let .success(results):
            return results
        case let .failure(error):
            throw error
        }
    }

    func fetchChanges(cursor: String?, limit: Int, accessToken: String) async throws -> SyncChangesResponseDTO {
        SyncChangesResponseDTO(
            changes: SyncChangesDTO(activityEvents: nil, focusSessions: nil),
            nextCursor: cursor ?? "",
            hasMore: false
        )
    }
}

/// In-memory `SyncCursorStore`.
final class InMemorySyncCursorStore: SyncCursorStore, @unchecked Sendable {
    private let lock = NSLock()
    private var cursor: String?

    func currentCursor() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cursor
    }

    func save(_ cursor: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.cursor = cursor
    }
}

// MARK: - Timing

struct FixedTestClock: Clock {
    let date: Date
    func now() -> Date {
        date
    }
}

/// Records every requested sleep duration instead of actually waiting, so
/// backoff/interval behavior is asserted on directly and tests stay
/// instantaneous — per the RIZ-41 brief's "ALL waits bounded" rule.
actor RecordingSleeper: Sleeper {
    private(set) var requestedDurations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        requestedDurations.append(duration)
    }
}
