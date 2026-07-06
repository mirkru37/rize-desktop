import Foundation

/// UI-facing sync status, per the RIZ-41 brief's "sync status in the menu
/// (signed-in state, last sync time)" requirement.
///
/// `@MainActor`-isolated so its `@Observable` properties are only ever
/// mutated on the main actor (RIZ-40 lesson); `SyncCoordinator` only ever
/// reads a snapshot before/after an `await`, never mutating this state
/// across one, matching the same rule the `H1` review flagged for
/// engine/store-adjacent code.
@MainActor
@Observable
final class SyncStatusViewModel {
    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastErrorMessage: String?

    func willStartCycle() {
        isSyncing = true
    }

    func didFinishCycle(at date: Date) {
        isSyncing = false
        lastSyncedAt = date
        lastErrorMessage = nil
    }

    func didFail(_ error: Error) {
        isSyncing = false
        lastErrorMessage = "\(error)"
    }
}

/// Drives `SyncEngine.runCycle()` on a repeating timer, per
/// `documentation/architecture-desktop.md` §Offline-First Store & Sync Loop
/// ("flushes the outbox every 60 seconds ... on flush failure, applies
/// exponential backoff before retrying").
///
/// An `actor` so `start()`/`stop()` and the internal retry/backoff state are
/// serialized; the injected `Sleeper` keeps both the steady 60s cadence and
/// the backoff delays bounded and instantaneous in tests (no wall-clock
/// waits, no unbounded loops).
actor SyncCoordinator {
    private let engine: SyncEngine
    private let sleeper: Sleeper
    private let clock: Clock
    private let interval: Duration
    private let initialBackoff: Duration
    private let maxBackoff: Duration
    private let statusViewModel: SyncStatusViewModel?

    private var loopTask: Task<Void, Never>?

    init(
        engine: SyncEngine,
        sleeper: Sleeper = TaskSleeper(),
        clock: Clock = SystemClock(),
        interval: Duration = .seconds(60),
        initialBackoff: Duration = .seconds(5),
        maxBackoff: Duration = .seconds(300),
        statusViewModel: SyncStatusViewModel? = nil
    ) {
        self.engine = engine
        self.sleeper = sleeper
        self.clock = clock
        self.interval = interval
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.statusViewModel = statusViewModel
    }

    /// Starts the periodic sync loop. No-op if already started.
    func start() {
        guard loopTask == nil else {
            return
        }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Runs a single cycle immediately, outside the periodic cadence (e.g.
    /// right after a successful login, so the user doesn't wait up to 60s
    /// for their first sync).
    func syncNow() async {
        await runCycleUpdatingStatus()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await runCycleUpdatingStatus()
            guard !Task.isCancelled else {
                return
            }
            try? await sleeper.sleep(for: interval)
        }
    }

    private func runCycleUpdatingStatus() async {
        await statusViewModel?.willStartCycle()
        do {
            try await runWithBackoff()
            await statusViewModel?.didFinishCycle(at: clock.now())
        } catch {
            await statusViewModel?.didFail(error)
        }
    }

    /// Runs one cycle, retrying with exponential backoff (capped at
    /// `maxBackoff`) on failure. Each retry attempt is itself bounded by the
    /// injected `Sleeper`, so tests never actually wait.
    private func runWithBackoff() async throws {
        var backoff = initialBackoff
        var lastError: Error?

        for attempt in 0 ... Self.maxRetryAttempts {
            do {
                try await engine.runCycle()
                return
            } catch {
                lastError = error
                guard attempt < Self.maxRetryAttempts else {
                    break
                }
                try? await sleeper.sleep(for: backoff)
                backoff = min(backoff * 2, maxBackoff)
            }
        }

        throw lastError ?? CancellationError()
    }

    private static let maxRetryAttempts = 3
}
