import Foundation
import XCTest
@testable import LocalFlowCore

final class DictationInsightsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testCalculatesWordsSpeedTimeSavedAndApplications() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let records = [
            record(
                text: "one two three four",
                createdAt: now,
                duration: 2,
                app: "Messages"
            ),
            record(
                text: "five six",
                createdAt: now.addingTimeInterval(-120),
                duration: 1,
                app: "Messages"
            ),
            record(
                text: "seven eight nine",
                createdAt: now.addingTimeInterval(-86_400),
                duration: 3,
                app: "Terminal"
            )
        ]

        let insights = DictationInsightsCalculator.make(
            records: records,
            now: now,
            calendar: calendar,
            dayCount: 7
        )

        XCTAssertEqual(insights.totalWords, 9)
        XCTAssertEqual(insights.totalDictations, 3)
        XCTAssertEqual(insights.totalDurationSeconds, 6)
        XCTAssertEqual(insights.averageWordsPerMinute, 90, accuracy: 0.001)
        XCTAssertEqual(insights.estimatedTimeSavedSeconds, 7.5, accuracy: 0.001)
        XCTAssertEqual(insights.longestDictationWords, 4)
        XCTAssertEqual(insights.topApplications.first?.name, "Messages")
        XCTAssertEqual(insights.topApplications.first?.words, 6)
    }

    func testBuildsDailySeriesAndCurrentStreak() {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_720_000_000))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: today)!
        let records = [
            record(text: "today words", createdAt: today, duration: 1, app: "Notes"),
            record(text: "yesterday", createdAt: yesterday, duration: 1, app: "Notes"),
            record(text: "two days", createdAt: twoDaysAgo, duration: 1, app: "Notes"),
            record(text: "older", createdAt: fourDaysAgo, duration: 1, app: "Notes")
        ]

        let insights = DictationInsightsCalculator.make(
            records: records,
            now: today,
            calendar: calendar,
            dayCount: 5
        )

        XCTAssertEqual(insights.currentStreakDays, 3)
        XCTAssertEqual(insights.activeDays, 4)
        XCTAssertEqual(insights.dailyStats.count, 5)
        XCTAssertEqual(insights.dailyStats.map(\.words), [1, 0, 2, 1, 2])
    }

    func testYesterdayStillCountsAsAnActiveStreak() {
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_720_000_000))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let insights = DictationInsightsCalculator.make(
            records: [record(text: "hello", createdAt: yesterday, duration: 1, app: "Notes")],
            now: today,
            calendar: calendar
        )

        XCTAssertEqual(insights.currentStreakDays, 1)
    }

    private func record(
        text: String,
        createdAt: Date,
        duration: TimeInterval,
        app: String
    ) -> DictationRecord {
        DictationRecord(
            createdAt: createdAt,
            targetApplication: TargetApplicationInfo(localizedName: app, bundleIdentifier: nil),
            transcribedText: text,
            finalText: text,
            polished: false,
            durationSeconds: duration
        )
    }
}
