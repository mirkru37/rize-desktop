import Foundation

/// Abstraction over suspending for a duration, so the sync loop's periodic
/// timer and its retry backoff are exercised in tests with an injected,
/// instantaneous fake rather than real wall-clock waits — per the RIZ-41
/// brief's "ALL waits bounded" standing rule (no unbounded loops, no
/// wall-clock sleeps in tests).
protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

/// Production sleeper backed by `Task.sleep`.
struct TaskSleeper: Sleeper {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
