// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// Add-on: summary numbers for the stats screen, computed from daemon history.
public struct BlockStats: Equatable {
    public var totalSeconds: TimeInterval
    public var blockCount: Int
    public var longestSeconds: TimeInterval
    public var currentStreakDays: Int
    public var longestStreakDays: Int
    /// Seconds blocked per calendar day for the trailing window, oldest first.
    public var daily: [(day: Date, seconds: TimeInterval)]

    public static func == (lhs: BlockStats, rhs: BlockStats) -> Bool {
        lhs.totalSeconds == rhs.totalSeconds && lhs.blockCount == rhs.blockCount
            && lhs.longestSeconds == rhs.longestSeconds && lhs.currentStreakDays == rhs.currentStreakDays
            && lhs.longestStreakDays == rhs.longestStreakDays
            && lhs.daily.map(\.seconds) == rhs.daily.map(\.seconds) && lhs.daily.map(\.day) == rhs.daily.map(\.day)
    }

    public static func compute(history: [HistoryEntry], active: ActiveBlock? = nil, now: Date = Date(),
                               days: Int = 14, calendar: Calendar = .current) -> BlockStats {
        // Treat the running block as a (partial) entry so today's chart and streak update live.
        var intervals = history.map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
        if let active, active.startDate < now { intervals.append(DateInterval(start: active.startDate, end: now)) }

        let total = intervals.reduce(0) { $0 + $1.duration }
        let longest = intervals.map(\.duration).max() ?? 0

        // Seconds per day, splitting blocks that cross midnight.
        var perDay: [Date: TimeInterval] = [:]
        for interval in intervals {
            var cursor = interval.start
            while cursor < interval.end {
                let dayStart = calendar.startOfDay(for: cursor)
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
                let sliceEnd = min(nextDay, interval.end)
                perDay[dayStart, default: 0] += sliceEnd.timeIntervalSince(cursor)
                cursor = sliceEnd
            }
        }

        let today = calendar.startOfDay(for: now)
        let daily: [(day: Date, seconds: TimeInterval)] = (0..<days).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, perDay[day] ?? 0)
        }

        let activeDays = Set(perDay.filter { $0.value >= 60 }.keys)

        // Current streak: consecutive days with a block, ending today (or yesterday if today has none yet).
        var current = 0
        var cursor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        while activeDays.contains(cursor) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }

        var longestStreak = 0
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day { run += 1 } else { run = 1 }
            longestStreak = max(longestStreak, run)
            previous = day
        }

        return BlockStats(totalSeconds: total, blockCount: history.count + (active == nil ? 0 : 1),
                          longestSeconds: longest, currentStreakDays: current,
                          longestStreakDays: longestStreak, daily: daily)
    }
}
