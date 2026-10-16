import Foundation

/// When the scheduler starts a job. Neither field set means the job only runs on demand.
public struct Schedule: Codable, Equatable, Sendable {
    public var calendar: [CalendarEntry]?
    public var intervalSeconds: Int?

    public init(calendar: [CalendarEntry]? = nil, intervalSeconds: Int? = nil) {
        self.calendar = calendar
        self.intervalSeconds = intervalSeconds
    }

    public static let manual = Schedule()

    public var isManual: Bool { (calendar ?? []).isEmpty && intervalSeconds == nil }

    func validationErrors() -> [String] {
        var errors: [String] = []
        if let i = intervalSeconds, i <= 0 { errors.append("schedule.intervalSeconds must be positive") }
        for entry in calendar ?? [] { errors.append(contentsOf: entry.validationErrors()) }
        return errors
    }

    /// Next time the scheduler will start the job. Interval jobs count from the end of the previous
    /// run (or from when the scheduler first saw the job), `nil` when neither is known.
    public func nextRun(after now: Date, lastRunEnd: Date?, calendar cal: Calendar = .current) -> NextRun? {
        var candidates: [NextRun] = []
        for entry in calendar ?? [] {
            if let date = entry.nextDate(after: now, calendar: cal) {
                candidates.append(NextRun(date: date, approximate: false))
            }
        }
        if let interval = intervalSeconds, let lastRunEnd {
            let due = lastRunEnd.addingTimeInterval(TimeInterval(interval))
            candidates.append(NextRun(date: max(due, now), approximate: false))
        }
        return candidates.min { $0.date < $1.date }
    }
}

public struct NextRun: Equatable, Sendable {
    public var date: Date
    public var approximate: Bool
}

/// One calendar entry, shaped like launchd's `StartCalendarInterval`. Missing fields are wildcards.
public struct CalendarEntry: Codable, Equatable, Sendable {
    public var minute: Int?
    public var hour: Int?
    public var day: Int?
    /// launchd numbering: 0 and 7 are Sunday.
    public var weekday: Int?
    public var month: Int?

    public init(minute: Int? = nil, hour: Int? = nil, day: Int? = nil, weekday: Int? = nil, month: Int? = nil) {
        self.minute = minute
        self.hour = hour
        self.day = day
        self.weekday = weekday
        self.month = month
    }

    func validationErrors() -> [String] {
        var errors: [String] = []
        func check(_ value: Int?, _ name: String, _ range: ClosedRange<Int>) {
            if let value, !range.contains(value) { errors.append("schedule.calendar.\(name) out of range \(range)") }
        }
        check(minute, "minute", 0...59)
        check(hour, "hour", 0...23)
        check(day, "day", 1...31)
        check(weekday, "weekday", 0...7)
        check(month, "month", 1...12)
        if let day, let month {
            let longest = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            if (1...12).contains(month), day > longest[month - 1] {
                errors.append("schedule.calendar: day \(day) never occurs in month \(month)")
            }
        }
        return errors
    }

    func nextDate(after now: Date, calendar cal: Calendar) -> Date? {
        // launchd follows cron: when both day and weekday are set, either one matching is enough.
        if day != nil, weekday != nil {
            let byDay = CalendarEntry(minute: minute, hour: hour, day: day, month: month)
            let byWeekday = CalendarEntry(minute: minute, hour: hour, weekday: weekday, month: month)
            return [byDay.nextDate(after: now, calendar: cal), byWeekday.nextDate(after: now, calendar: cal)]
                .compactMap { $0 }.min()
        }
        // A missing minute means every minute of the matching hours, so the very next minute counts
        // when it still matches the other fields.
        if minute == nil, let nextMinute = cal.dateInterval(of: .minute, for: now)?.end, matches(nextMinute, cal) {
            return nextMinute
        }
        var components = DateComponents()
        components.second = 0
        components.minute = minute ?? (hour != nil ? 0 : nil)
        components.hour = hour
        components.day = day
        components.month = month
        if let weekday { components.weekday = weekday % 7 + 1 }
        // `.strict` skips months without the requested day instead of sliding into the next month.
        return cal.nextDate(after: now, matching: components, matchingPolicy: .strict)
    }

    private func matches(_ date: Date, _ cal: Calendar) -> Bool {
        let c = cal.dateComponents([.hour, .day, .month, .weekday], from: date)
        if let hour, c.hour != hour { return false }
        if let day, c.day != day { return false }
        if let month, c.month != month { return false }
        if let weekday, c.weekday != weekday % 7 + 1 { return false }
        return true
    }
}
