import Foundation

public struct DictationDayStat: Equatable, Identifiable, Sendable {
    public var date: Date
    public var words: Int
    public var dictations: Int
    public var durationSeconds: TimeInterval

    public var id: Date { date }
}

public struct DictationApplicationStat: Equatable, Identifiable, Sendable {
    public var name: String
    public var words: Int
    public var dictations: Int

    public var id: String { name }
}

public struct DictationInsights: Equatable, Sendable {
    public var totalWords: Int
    public var totalDictations: Int
    public var totalDurationSeconds: TimeInterval
    public var estimatedTimeSavedSeconds: TimeInterval
    public var averageWordsPerMinute: Double
    public var currentStreakDays: Int
    public var activeDays: Int
    public var longestDictationWords: Int
    public var dailyStats: [DictationDayStat]
    public var topApplications: [DictationApplicationStat]

    public static let empty = DictationInsights(
        totalWords: 0,
        totalDictations: 0,
        totalDurationSeconds: 0,
        estimatedTimeSavedSeconds: 0,
        averageWordsPerMinute: 0,
        currentStreakDays: 0,
        activeDays: 0,
        longestDictationWords: 0,
        dailyStats: [],
        topApplications: []
    )
}

public enum DictationInsightsCalculator {
    public static func make(
        records: [DictationRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        dayCount: Int = 14,
        assumedTypingWordsPerMinute: Double = 40
    ) -> DictationInsights {
        let safeDayCount = max(1, dayCount)
        let totalWords = records.reduce(0) { $0 + wordCount(in: $1.finalText) }
        let totalDuration = records.compactMap(\.durationSeconds).reduce(0, +)
        let averageWPM = totalDuration > 0
            ? Double(totalWords) / (totalDuration / 60)
            : 0
        let typingDuration = assumedTypingWordsPerMinute > 0
            ? Double(totalWords) / assumedTypingWordsPerMinute * 60
            : 0

        var statsByDay: [Date: (words: Int, dictations: Int, duration: TimeInterval)] = [:]
        var appStats: [String: (words: Int, dictations: Int)] = [:]
        var longestDictationWords = 0

        for record in records {
            let words = wordCount(in: record.finalText)
            longestDictationWords = max(longestDictationWords, words)

            let day = calendar.startOfDay(for: record.createdAt)
            var dayStat = statsByDay[day] ?? (0, 0, 0)
            dayStat.words += words
            dayStat.dictations += 1
            dayStat.duration += record.durationSeconds ?? 0
            statsByDay[day] = dayStat

            let appName = record.targetApplication?.displayName ?? "Unknown app"
            var appStat = appStats[appName] ?? (0, 0)
            appStat.words += words
            appStat.dictations += 1
            appStats[appName] = appStat
        }

        let today = calendar.startOfDay(for: now)
        let dailyStats = (0..<safeDayCount).reversed().compactMap { offset -> DictationDayStat? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else {
                return nil
            }
            let stat = statsByDay[date] ?? (0, 0, 0)
            return DictationDayStat(
                date: date,
                words: stat.words,
                dictations: stat.dictations,
                durationSeconds: stat.duration
            )
        }

        let activeDates = Set(statsByDay.keys)
        let streakStart: Date?
        if activeDates.contains(today) {
            streakStart = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  activeDates.contains(yesterday) {
            streakStart = yesterday
        } else {
            streakStart = nil
        }

        var streak = 0
        var cursor = streakStart
        while let date = cursor, activeDates.contains(date) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: date)
        }

        let topApplications = appStats
            .map { name, stats in
                DictationApplicationStat(name: name, words: stats.words, dictations: stats.dictations)
            }
            .sorted {
                if $0.words == $1.words {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.words > $1.words
            }

        return DictationInsights(
            totalWords: totalWords,
            totalDictations: records.count,
            totalDurationSeconds: totalDuration,
            estimatedTimeSavedSeconds: max(0, typingDuration - totalDuration),
            averageWordsPerMinute: averageWPM,
            currentStreakDays: streak,
            activeDays: activeDates.count,
            longestDictationWords: longestDictationWords,
            dailyStats: dailyStats,
            topApplications: topApplications
        )
    }

    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
