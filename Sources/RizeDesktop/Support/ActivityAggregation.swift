import Foundation

/// Pure aggregation over a day's `activity_events`, factored out of
/// `MenuContentViewModel` so it's unit-testable without going through
/// `@Observable`/async view-model plumbing.
enum ActivityAggregation {
    /// A single app's total tracked duration for the summarized period.
    struct AppUsage: Identifiable, Equatable {
        var bundleID: String
        var duration: TimeInterval

        var id: String {
            bundleID
        }
    }

    /// The menu's today-summary numbers: total tracked time and the
    /// top apps by tracked duration, per
    /// `documentation/architecture-desktop.md` §Component Diagram.
    struct Summary: Equatable {
        var totalTrackedTime: TimeInterval
        var topApps: [AppUsage]

        static let empty = Summary(totalTrackedTime: 0, topApps: [])
    }

    /// Sums `appActive` event durations — idle/locked segments are not
    /// "tracked time" — and ranks apps by total duration, descending,
    /// keeping only the top `topAppsLimit`. Events of other types, or
    /// missing a bundle id, are ignored for the per-app breakdown but any
    /// non-positive-duration row is ignored entirely as defensive noise
    /// filtering (closed segments should never be non-positive by
    /// construction, but the view model must not crash or show negative
    /// numbers if one ever is).
    static func summarize(events: [ActivityEvent], topAppsLimit: Int) -> Summary {
        var durationByApp: [String: TimeInterval] = [:]
        var total: TimeInterval = 0

        for event in events where event.type == .appActive {
            let duration = event.endedAt.timeIntervalSince(event.startedAt)
            guard duration > 0 else {
                continue
            }
            total += duration
            guard let bundleID = event.appBundleID else {
                continue
            }
            durationByApp[bundleID, default: 0] += duration
        }

        let topApps = durationByApp
            .map { AppUsage(bundleID: $0.key, duration: $0.value) }
            .sorted { $0.duration > $1.duration }
            .prefix(topAppsLimit)

        return Summary(totalTrackedTime: total, topApps: Array(topApps))
    }

    /// Formats a duration for display as `"1h 5m"` (hours present) or
    /// `"45m"` (no whole hour), floored to the minute. Negative durations
    /// are clamped to zero rather than shown as `"-5m"`.
    static func formatDuration(_ duration: TimeInterval) -> String {
        let totalMinutes = max(Int(duration / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else {
            return "\(minutes)m"
        }
        return "\(hours)h \(minutes)m"
    }
}
