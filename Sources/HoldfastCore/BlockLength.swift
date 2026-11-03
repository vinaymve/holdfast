// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// How long a block lasts: either a fixed duration, or until the next occurrence of a clock time.
/// This replaces the original's drag slider.
public enum BlockLength: Equatable, Codable {
    case duration(minutes: Int)
    case until(hour: Int, minute: Int)

    /// The moment the block should end if started at `now`.
    /// `.until` picks the next time the clock reads hour:minute, so "until 5 PM" at 6 PM means tomorrow.
    public func endDate(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .duration(let minutes):
            return now.addingTimeInterval(TimeInterval(minutes) * 60)
        case .until(let hour, let minute):
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            return calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(86_400)
        }
    }
}

public enum DurationParser {
    /// Parses "90", "45m", "2h", "1.5h", "1h30m", "1h 30", "2 hours", "1:30" into minutes.
    /// A lone number is minutes.
    public static func minutes(from text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }

        if let colon = s.firstIndex(of: ":") {
            let h = s[..<colon], m = s[s.index(after: colon)...]
            guard let hours = Int(h), let mins = Int(m), mins < 60 else { return nil }
            return hours * 60 + mins
        }

        let pattern = #"(\d+(?:\.\d+)?)\s*([a-z]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        // Everything must be consumed by number/unit pairs (no stray words).
        let stripped = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        guard stripped.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        var total = 0.0
        var sawHours = false
        for (index, match) in matches.enumerated() {
            guard let value = Double(ns.substring(with: match.range(at: 1))) else { return nil }
            let unit = ns.substring(with: match.range(at: 2))
            switch unit {
            case "h", "hr", "hrs", "hour", "hours":
                total += value * 60
                sawHours = true
            case "m", "min", "mins", "minute", "minutes":
                total += value
            case "":
                // Bare number: minutes, unless it trails an hours token ("1h 30").
                if matches.count == 1 || (index > 0 && sawHours) { total += value } else { return nil }
            default:
                return nil
            }
        }
        let rounded = Int(total.rounded())
        return rounded > 0 ? rounded : nil
    }
}

public struct TimeOfDay: Equatable, Codable, Hashable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    /// Parses "17:30", "5:30pm", "5pm", "530 pm", "1730".
    public static func parse(_ text: String) -> TimeOfDay? {
        var s = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm"] where s.hasSuffix(suffix) {
            meridiem = suffix
            s = String(s.dropLast(2))
        }
        var hour: Int, minute: Int
        if let colon = s.firstIndex(of: ":") {
            guard let h = Int(s[..<colon]), let m = Int(s[s.index(after: colon)...]) else { return nil }
            hour = h; minute = m
        } else if s.count == 4, let n = Int(s) {
            hour = n / 100; minute = n % 100
        } else if let h = Int(s), s.count <= 2 {
            hour = h; minute = 0
        } else {
            return nil
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "am" { hour = hour % 12 } else { hour = hour % 12 + 12 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

public enum Format {
    /// "2h 14m", "45m", "3d 2h", "less than a minute"
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total < 60 { return total == 0 ? "0m" : "less than a minute" }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// "02:14:05" countdown.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
