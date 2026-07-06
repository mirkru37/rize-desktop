import Foundation

/// The subset of `TrackingEngine`'s API the presentation layer depends on.
/// `MenuContentViewModel` is written against this protocol rather than the
/// concrete actor so it can be exercised in tests with a stub, without
/// pulling in the real state machine or a `LocalStore`.
///
/// `TrackingEngine` conforms below purely by having matching actor-isolated
/// members: an actor's synchronous, isolated properties and methods satisfy
/// `async` protocol requirements, since every access from outside the actor
/// already requires `await`.
protocol TrackingEngineControlling: Sendable {
    var state: TrackingLifecycleState { get async }
    var permissionState: AccessibilityPermissionState { get async }
    var isPaused: Bool { get async }

    /// Stops producing persistable segments until `resume()` is called.
    func pause() async
    /// Resumes producing persistable segments after `pause()`.
    func resume() async
}

extension TrackingEngine: TrackingEngineControlling {}
