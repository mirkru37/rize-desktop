import Foundation
@testable import RizeDesktop

// Sync-layer and timing test doubles for the RIZ-41 auth/sync suite,
// split out of `SyncAuthTestDoubles.swift` (which keeps `TestError`,
// `makeAuthResponse`, and the auth-side fakes) purely to stay under the
// SwiftLint `file_length` gate — both files are part of the same shared
// fixture set used by `AuthTokenManagerTests`, `AuthorizingSyncAPIClientTests`,
// `SyncEngineTests`, and `SyncCoordinatorTests`.

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

    /// Releases exactly the oldest `pushEvents` call currently suspended at
    /// the gate (FIFO), leaving the gate armed for subsequent arrivals. Lets
    /// a test stage releases one caller at a time instead of all-at-once.
    func releaseOneWaiter() {
        guard !gateWaiters.isEmpty else { return }
        let waiter = gateWaiters.removeFirst()
        waiter.resume()
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
