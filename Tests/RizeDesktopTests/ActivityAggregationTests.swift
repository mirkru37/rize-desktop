@testable import RizeDesktop
import XCTest

/// Exercises `ActivityAggregation`'s pure summarization and formatting,
/// which back the menu-bar dashboard's "today" summary
/// (`documentation/architecture-desktop.md` §Component Diagram).
final class ActivityAggregationTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent(
        type: ActivityEventType,
        appBundleID: String?,
        durationSeconds: TimeInterval
    ) -> ActivityEvent {
        ActivityEvent(
            eventID: UUID(),
            startedAt: referenceDate,
            endedAt: referenceDate.addingTimeInterval(durationSeconds),
            type: type,
            appBundleID: appBundleID,
            insertedAt: referenceDate
        )
    }

    // MARK: - summarize

    func testSummarizeSumsAppActiveDurationsAndIgnoresOtherTypes() {
        let editorEvent = makeEvent(type: .appActive, appBundleID: "com.acme.Editor", durationSeconds: 600)
        let idleEvent = makeEvent(type: .idle, appBundleID: nil, durationSeconds: 120)
        let lockedEvent = makeEvent(type: .locked, appBundleID: nil, durationSeconds: 60)

        let summary = ActivityAggregation.summarize(events: [editorEvent, idleEvent, lockedEvent], topAppsLimit: 3)

        XCTAssertEqual(summary.totalTrackedTime, 600, accuracy: 0.001)
        XCTAssertEqual(summary.topApps, [.init(bundleID: "com.acme.Editor", duration: 600)])
    }

    func testSummarizeRanksTopAppsDescendingAndRespectsLimit() {
        let eventA = makeEvent(type: .appActive, appBundleID: "com.acme.A", durationSeconds: 100)
        let eventB = makeEvent(type: .appActive, appBundleID: "com.acme.B", durationSeconds: 300)
        let eventC = makeEvent(type: .appActive, appBundleID: "com.acme.C", durationSeconds: 200)

        let summary = ActivityAggregation.summarize(events: [eventA, eventB, eventC], topAppsLimit: 2)

        XCTAssertEqual(summary.topApps.map(\.bundleID), ["com.acme.B", "com.acme.C"])
        XCTAssertEqual(summary.totalTrackedTime, 600, accuracy: 0.001)
    }

    func testSummarizeBreaksDurationTiesByAscendingBundleID() {
        let eventZebra = makeEvent(type: .appActive, appBundleID: "com.acme.Zebra", durationSeconds: 100)
        let eventApple = makeEvent(type: .appActive, appBundleID: "com.acme.Apple", durationSeconds: 100)
        let eventMango = makeEvent(type: .appActive, appBundleID: "com.acme.Mango", durationSeconds: 100)

        let summary = ActivityAggregation.summarize(
            events: [eventZebra, eventApple, eventMango],
            topAppsLimit: 3
        )

        XCTAssertEqual(
            summary.topApps.map(\.bundleID),
            ["com.acme.Apple", "com.acme.Mango", "com.acme.Zebra"]
        )
    }

    func testSummarizeTieBreakIsStableAcrossTheTopAppsLimitBoundary() {
        // All four apps tie on duration; only the alphabetically-first two
        // should survive the limit, in ascending bundleID order — the tie
        // straddles the `topAppsLimit` cutoff rather than falling entirely
        // inside or outside it.
        let eventDelta = makeEvent(type: .appActive, appBundleID: "com.acme.Delta", durationSeconds: 100)
        let eventAlpha = makeEvent(type: .appActive, appBundleID: "com.acme.Alpha", durationSeconds: 100)
        let eventCharlie = makeEvent(type: .appActive, appBundleID: "com.acme.Charlie", durationSeconds: 100)
        let eventBravo = makeEvent(type: .appActive, appBundleID: "com.acme.Bravo", durationSeconds: 100)

        let summary = ActivityAggregation.summarize(
            events: [eventDelta, eventAlpha, eventCharlie, eventBravo],
            topAppsLimit: 2
        )

        XCTAssertEqual(summary.topApps.map(\.bundleID), ["com.acme.Alpha", "com.acme.Bravo"])
    }

    func testSummarizeAccumulatesMultipleEventsForTheSameApp() {
        let firstEvent = makeEvent(type: .appActive, appBundleID: "com.acme.Editor", durationSeconds: 100)
        let secondEvent = makeEvent(type: .appActive, appBundleID: "com.acme.Editor", durationSeconds: 50)

        let summary = ActivityAggregation.summarize(events: [firstEvent, secondEvent], topAppsLimit: 3)

        XCTAssertEqual(summary.topApps, [.init(bundleID: "com.acme.Editor", duration: 150)])
    }

    func testSummarizeCountsTotalTimeButOmitsAppsWithNoBundleIDFromTheBreakdown() {
        let event = makeEvent(type: .appActive, appBundleID: nil, durationSeconds: 100)

        let summary = ActivityAggregation.summarize(events: [event], topAppsLimit: 3)

        XCTAssertEqual(summary.totalTrackedTime, 100, accuracy: 0.001)
        XCTAssertEqual(summary.topApps, [])
    }

    func testSummarizeIgnoresNonPositiveDurationEvents() {
        let events = [makeEvent(type: .appActive, appBundleID: "com.acme.Editor", durationSeconds: 0)]

        let summary = ActivityAggregation.summarize(events: events, topAppsLimit: 3)

        XCTAssertEqual(summary, .empty)
    }

    func testSummarizeOfEmptyEventsIsEmptySummary() {
        XCTAssertEqual(ActivityAggregation.summarize(events: [], topAppsLimit: 3), .empty)
    }

    // MARK: - formatDuration

    func testFormatDurationBelowOneHourShowsMinutesOnly() {
        XCTAssertEqual(ActivityAggregation.formatDuration(45 * 60), "45m")
    }

    func testFormatDurationWithWholeHoursShowsHoursAndMinutes() {
        XCTAssertEqual(ActivityAggregation.formatDuration(65 * 60), "1h 5m")
    }

    func testFormatDurationZeroIsZeroMinutes() {
        XCTAssertEqual(ActivityAggregation.formatDuration(0), "0m")
    }

    func testFormatDurationFloorsPartialMinutes() {
        XCTAssertEqual(ActivityAggregation.formatDuration(119), "1m")
    }

    func testFormatDurationClampsNegativeToZero() {
        XCTAssertEqual(ActivityAggregation.formatDuration(-30), "0m")
    }
}
