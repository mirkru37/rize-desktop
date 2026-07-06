@testable import RizeDesktop
import XCTest

/// Exercises `SyncCoordinator`'s bounded exponential backoff against a
/// `RecordingSleeper` (no real waits) and a scripted `SyncEngine` stand-in,
/// per `documentation/architecture-desktop.md` §Offline-First Store & Sync
/// Loop ("on flush failure, applies exponential backoff before retrying")
/// and the RIZ-41 brief's "ALL waits bounded" rule.
final class SyncCoordinatorTests: XCTestCase {
    /// A minimal `LocalStore` that reports an empty outbox and an empty
    /// pull page, so `SyncEngine.runCycle()` succeeds trivially — these
    /// tests are about `SyncCoordinator`'s retry/backoff wrapper, not
    /// `SyncEngine` itself (covered by `SyncEngineTests`).
    private actor EmptyLocalStore: LocalStore {
        func writeEvent(_ event: ActivityEvent) async throws {}
        func tombstoneEvent(id: UUID, at date: Date) async throws {}
        func upsertSession(_ session: FocusSession) async throws {}
        func tombstoneSession(id: UUID, at date: Date) async throws {}
        func fetchTodayActivity() async throws -> [ActivityEvent] {
            []
        }

        func fetchUnsyncedEvents(limit: Int) async throws -> [ActivityEvent] {
            []
        }

        func markEventsSynced(ids: [UUID], syncedAt date: Date) async throws {}
    }

    /// A `SyncAPIClient` whose `fetchChanges` fails a configured number of
    /// times before succeeding, so `SyncEngine.runCycle()`'s failure comes
    /// from the pull leg without needing any outbox setup.
    private actor FlakyFetchSyncAPIClient: SyncAPIClient {
        private var remainingFailures: Int

        init(failures: Int) {
            remainingFailures = failures
        }

        func pushEvents(_ items: [SyncPushItemDTO], deviceID: String) async throws -> [SyncPushResultDTO] {
            []
        }

        func fetchChanges(cursor: String?, limit: Int) async throws -> SyncChangesResponseDTO {
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw TestError.network
            }
            return SyncChangesResponseDTO(
                changes: SyncChangesDTO(activityEvents: nil, focusSessions: nil),
                nextCursor: "",
                hasMore: false
            )
        }
    }

    private func makeEngine(syncAPI: SyncAPIClient) -> SyncEngine {
        let tokenManager = AuthTokenManager(api: FakeAuthAPIClient(), storage: InMemoryAuthTokenStorage())
        return SyncEngine(
            localStore: EmptyLocalStore(),
            syncAPI: syncAPI,
            cursorStore: InMemorySyncCursorStore(),
            tokenManager: tokenManager
        )
    }

    func testSyncNowRetriesWithDoublingBackoffThenSucceeds() async {
        let engine = makeEngine(syncAPI: FlakyFetchSyncAPIClient(failures: 2))
        let sleeper = RecordingSleeper()
        let statusViewModel = await SyncStatusViewModel()
        let coordinator = SyncCoordinator(
            engine: engine,
            sleeper: sleeper,
            initialBackoff: .seconds(5),
            maxBackoff: .seconds(300),
            statusViewModel: statusViewModel
        )

        await coordinator.syncNow()

        let durations = await sleeper.requestedDurations
        XCTAssertEqual(durations, [.seconds(5), .seconds(10)])
        let lastErrorMessage = await statusViewModel.lastErrorMessage
        XCTAssertNil(lastErrorMessage, "the cycle ultimately succeeded")
        let lastSyncedAt = await statusViewModel.lastSyncedAt
        XCTAssertNotNil(lastSyncedAt)
    }

    func testSyncNowCapsBackoffAtMaxAndReportsFailureAfterExhaustingRetries() async {
        let engine = makeEngine(syncAPI: FlakyFetchSyncAPIClient(failures: 100))
        let sleeper = RecordingSleeper()
        let statusViewModel = await SyncStatusViewModel()
        let coordinator = SyncCoordinator(
            engine: engine,
            sleeper: sleeper,
            initialBackoff: .seconds(5),
            maxBackoff: .seconds(15),
            statusViewModel: statusViewModel
        )

        await coordinator.syncNow()

        // initialBackoff=5, doubled to 10, doubled again would be 20 but
        // capped at maxBackoff=15.
        let durations = await sleeper.requestedDurations
        XCTAssertEqual(durations, [.seconds(5), .seconds(10), .seconds(15)])
        let lastErrorMessage = await statusViewModel.lastErrorMessage
        XCTAssertNotNil(lastErrorMessage, "retries are exhausted, the cycle must report failure")
    }
}
