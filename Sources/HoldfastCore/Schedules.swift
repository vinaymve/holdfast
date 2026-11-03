// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

extension Schedule {
    public static let weekdayNumbers = [2, 3, 4, 5, 6]

    /// Validation shared by the daemon (authoritative) and the UI.
    public func validate(maxMinutes: Int = Int(SC.maxBlockSeconds / 60)) throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            throw SCError(.invalidSchedule, "Give the schedule a name.")
        }
        if weekdays.isEmpty || !weekdays.allSatisfy({ (1...7).contains($0) }) {
            throw SCError(.invalidSchedule, "Pick at least one day.")
        }
        if !(0...23).contains(startHour) || !(0...59).contains(startMinute) {
            throw SCError(.invalidSchedule, "The start time isn't valid.")
        }
        if durationMinutes < 1 || durationMinutes > maxMinutes {
            throw SCError(.invalidSchedule, "The length must be between 1 minute and \(maxMinutes / 60) hours.")
        }
        if profile.entries.isEmpty && profile.apps.isEmpty && !profile.isAllowlist {
            throw SCError(.invalidSchedule, "The profile has nothing to block.")
        }
    }

    private func windowStart(onDayOf day: Date, calendar: Calendar) -> Date? {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = startHour
        comps.minute = startMinute
        comps.second = 0
        return calendar.date(from: comps)
    }

    /// The window (start..end) that contains `date`, if this schedule is active at that moment.
    /// Looks back far enough that a window that began on an earlier day (e.g. 22:00 for 8h) is found.
    public func window(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard enabled else { return nil }
        let lookbackDays = durationMinutes / 1_440 + 1
        for offset in 0...lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date),
                  let start = windowStart(onDayOf: day, calendar: calendar),
                  weekdays.contains(calendar.component(.weekday, from: start)) else { continue }
            let end = start.addingTimeInterval(TimeInterval(durationMinutes) * 60)
            if start <= date && date < end { return DateInterval(start: start, end: end) }
        }
        return nil
    }

    /// Next window start strictly after `date`.
    public func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date),
                  let start = windowStart(onDayOf: day, calendar: calendar),
                  weekdays.contains(calendar.component(.weekday, from: start)),
                  start > date else { continue }
            return start
        }
        return nil
    }

    public var endTimeOfDay: TimeOfDay {
        let total = (startHour * 60 + startMinute + durationMinutes) % 1_440
        return TimeOfDay(hour: total / 60, minute: total % 60)
    }
}

public enum SchedulePolicy {
    /// How many times a schedule tries to start its block within one window before giving up.
    public static let maxStartAttempts = 5
    public static let retryInterval: TimeInterval = 60
}
