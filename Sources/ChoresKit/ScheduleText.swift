import Foundation

/// The languages the app's texts come in. `ChoresKit` carries no resource bundle (the runner is a
/// single file in `~/.local/bin`), so the few texts it builds for the app take the language as a
/// parameter instead of reading a string catalog.
public enum Language: String, Sendable, CaseIterable {
    case english = "en"
    case turkish = "tr"
}

public enum ScheduleText {
    private struct Words {
        let weekdays: [String]
        let months: [String]
        let manual: String
        let everyDay: String
        let every: (_ count: Int, _ unit: Unit) -> String
        let monthDay: (Int) -> String
        let inMonth: (_ month: String, _ rest: String) -> String
        let at: (_ hour: Int, _ minute: Int) -> String
        let hourEveryMinute: (Int) -> String
        let everyHourAt: (Int) -> String
        let everyMinute: String
        let duration: (_ seconds: Double) -> String
    }

    enum Unit { case week, day, hour, minute, second }

    private static func words(_ language: Language) -> Words {
        switch language {
        case .english:
            Words(
                weekdays: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
                months: ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"],
                manual: "Manual only",
                everyDay: "Every day",
                every: { count, unit in
                    let name = switch unit {
                    case .week: "week"
                    case .day: "day"
                    case .hour: "hour"
                    case .minute: "minute"
                    case .second: "second"
                    }
                    return count == 1 ? "Every \(name)" : "Every \(count) \(name)s"
                },
                monthDay: { "On day \($0) of every month" },
                inMonth: { month, rest in "\(rest) in \(month)" },
                at: { String(format: "at %02d:%02d", $0, $1) },
                hourEveryMinute: { String(format: "every minute %02d:00–%02d:59", $0, $0) },
                everyHourAt: { String(format: "every hour at :%02d", $0) },
                everyMinute: "every minute",
                duration: { seconds in
                    if seconds < 1 { return "<1 s" }
                    let total = Int(seconds.rounded())
                    if total < 60 { return "\(total) s" }
                    if total < 3_600 { return "\(total / 60) min \(total % 60) s" }
                    return "\(total / 3_600) h \(total % 3_600 / 60) min"
                })
        case .turkish:
            Words(
                weekdays: ["Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"],
                months: ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül",
                         "Ekim", "Kasım", "Aralık"],
                manual: "Yalnızca elle",
                everyDay: "Her gün",
                every: { count, unit in
                    let name = switch unit {
                    case .week: "haftada bir"
                    case .day: "günde bir"
                    case .hour: "saatte bir"
                    case .minute: "dakikada bir"
                    case .second: "saniyede bir"
                    }
                    guard count == 1 else { return "Her \(count) \(name)" }
                    return name.prefix(1).uppercased(with: Locale(identifier: "tr_TR")) + name.dropFirst()
                },
                monthDay: { "Her ayın \($0). günü" },
                inMonth: { month, rest in "\(month) ayında \(rest.lowercased(with: Locale(identifier: "tr_TR")))" },
                at: { String(format: "%02d:%02d", $0, $1) },
                hourEveryMinute: { String(format: "%02d:00–%02d:59 arası her dakika", $0, $0) },
                everyHourAt: { String(format: "her saat :%02d", $0) },
                everyMinute: "her dakika",
                duration: { seconds in
                    if seconds < 1 { return "<1 sn" }
                    let total = Int(seconds.rounded())
                    if total < 60 { return "\(total) sn" }
                    if total < 3_600 { return "\(total / 60) dk \(total % 60) sn" }
                    return "\(total / 3_600) sa \(total % 3_600 / 60) dk"
                })
        }
    }

    public static func describe(_ schedule: Schedule, language: Language = .english) -> String {
        var parts: [String] = (schedule.calendar ?? []).map { describe($0, language: language) }
        if let interval = schedule.intervalSeconds {
            parts.append(describeInterval(interval, language: language))
        }
        return parts.isEmpty ? words(language).manual : parts.joined(separator: ", ")
    }

    public static func describeInterval(_ seconds: Int, language: Language = .english) -> String {
        let every = words(language).every
        if seconds % 604_800 == 0 { return every(seconds / 604_800, .week) }
        if seconds % 86_400 == 0 { return every(seconds / 86_400, .day) }
        if seconds % 3_600 == 0 { return every(seconds / 3_600, .hour) }
        if seconds % 60 == 0 { return every(seconds / 60, .minute) }
        return every(seconds, .second)
    }

    public static func describe(_ entry: CalendarEntry, language: Language = .english) -> String {
        let w = words(language)
        var prefix: String
        if let weekday = entry.weekday {
            prefix = language == .english ? "Every \(w.weekdays[((weekday % 7) + 7) % 7])"
                                          : "Her \(w.weekdays[((weekday % 7) + 7) % 7])"
        } else if let day = entry.day {
            prefix = w.monthDay(day)
        } else {
            prefix = w.everyDay
        }
        let time: String
        switch (entry.hour, entry.minute) {
        case let (hour?, minute?): time = w.at(hour, minute)
        case let (hour?, nil): time = w.hourEveryMinute(hour)
        case let (nil, minute?): time = w.everyHourAt(minute)
        case (nil, nil): time = w.everyMinute
        }
        let text = "\(prefix) \(time)"
        guard let month = entry.month, (1...12).contains(month) else { return text }
        return w.inMonth(w.months[month - 1], text)
    }

    public static func duration(_ seconds: Double, language: Language = .english) -> String {
        words(language).duration(seconds)
    }
}
