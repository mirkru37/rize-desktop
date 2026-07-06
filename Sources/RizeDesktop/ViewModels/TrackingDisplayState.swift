import Foundation

/// The tracking status the menu-bar UI presents to the user: the user-facing
/// "paused" override layered on top of the Tracking Engine's
/// `TrackingLifecycleState`, per
/// `documentation/architecture-desktop.md` §Component Diagram.
enum TrackingDisplayState: Equatable {
    case tracking
    case idle
    case locked
    case sleeping
    case paused

    /// - Parameters:
    ///   - lifecycleState: The engine's underlying state machine state.
    ///   - isPaused: Whether the user has paused tracking; takes priority
    ///     over `lifecycleState` since pausing does not change the
    ///     underlying state machine (see `TrackingEngine.pause()`).
    init(lifecycleState: TrackingLifecycleState, isPaused: Bool) {
        guard !isPaused else {
            self = .paused
            return
        }
        switch lifecycleState {
        case .active: self = .tracking
        case .idle: self = .idle
        case .locked: self = .locked
        case .sleeping: self = .sleeping
        }
    }

    /// Short label for the menu's status line.
    var label: String {
        switch self {
        case .tracking: "Tracking"
        case .idle: "Idle"
        case .locked: "Locked"
        case .sleeping: "Sleeping"
        case .paused: "Paused"
        }
    }
}
