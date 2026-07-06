import Foundation

/// Abstraction over "now" so time-dependent code (the local store's "today"
/// boundary, timestamps written on insert) can be exercised deterministically
/// in tests instead of depending on the wall clock.
protocol Clock: Sendable {
    func now() -> Date
}

/// Production clock backed by the system wall clock.
struct SystemClock: Clock {
    func now() -> Date {
        Date()
    }
}
