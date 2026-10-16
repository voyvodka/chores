import ChoresKit
import SwiftUI

enum Fmt {
    /// Follows the app's language (Settings › Language) and the user's region.
    static var locale: Locale { .autoupdatingCurrent }

    /// The language the app's strings resolved to; `ChoresKit` texts are built in the same one.
    static var language: Language {
        Bundle.main.preferredLocalizations.first?.hasPrefix("tr") == true ? .turkish : .english
    }

    static func schedule(_ schedule: Schedule) -> String { ScheduleText.describe(schedule, language: language) }
    static func duration(_ seconds: Double) -> String { ScheduleText.duration(seconds, language: language) }
    /// By the app's language rather than the region: "%80" in Turkish, "80%" in English, even with a
    /// Turkish region.
    static func percent(_ rate: Double) -> String {
        let locale = Locale(identifier: language == .turkish ? "tr_TR" : "en_US")
        return rate.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// A job category as shown; jobs without one are grouped under a translated "Other".
    static func category(_ category: String) -> String {
        category == JobOverview.uncategorized ? String(localized: "Other") : category.capitalized(with: locale)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        // `TimelineView(.everyMinute)` passes the start of the minute, which is before a run that
        // ended within it; without the clamp that run read as "in 15 seconds".
        return formatter.localizedString(for: date, relativeTo: max(now, date))
    }

    static func absolute(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// Short enough for a table column: "16 Eki 17:37" this year, "28 Ara 2025" before it.
    static func runDate(_ date: Date, now: Date = Date()) -> String {
        guard Calendar.current.isDate(date, equalTo: now, toGranularity: .year) else {
            return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale).year(.omitted))
    }

    /// Always "HH:mm", matching `ScheduleText`.
    static func clock(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Compact form for tight spots: "10:00", "Tomorrow 10:00", "1 Oct", prefixed with "~" when approximate.
    /// `midSentence` gives "tomorrow 10:00" for use after "next".
    static func nextRunShort(_ next: NextRun, midSentence: Bool = false) -> String {
        let cal = Calendar.current
        let text: String
        if cal.isDateInToday(next.date) {
            text = clock(next.date)
        } else if cal.isDateInTomorrow(next.date) {
            text = midSentence ? String(localized: "tomorrow \(clock(next.date))")
                               : String(localized: "Tomorrow \(clock(next.date))")
        } else {
            text = next.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
                .year(.omitted))
        }
        return next.approximate ? "~\(text)" : text
    }

    /// "Today 10:00", "Tomorrow 10:00", or a short date, prefixed with "~" when approximate.
    static func nextRun(_ next: NextRun, midSentence: Bool = false) -> String {
        let cal = Calendar.current
        let text: String
        if cal.isDateInToday(next.date) {
            text = midSentence ? String(localized: "today \(clock(next.date))")
                               : String(localized: "Today \(clock(next.date))")
        } else if cal.isDateInTomorrow(next.date) {
            text = midSentence ? String(localized: "tomorrow \(clock(next.date))")
                               : String(localized: "Tomorrow \(clock(next.date))")
        } else {
            text = absolute(next.date)
        }
        return next.approximate ? "~\(text)" : text
    }
}

extension Outcome {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        }
    }

    var label: String {
        switch self {
        case .ok: String(localized: "Succeeded")
        case .warn: String(localized: "Warning")
        case .fail: String(localized: "Failed")
        }
    }

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .ok: "checklist"
        case .warn: "exclamationmark.triangle"
        case .fail: "xmark.octagon"
        }
    }
}

extension LoadState {
    var label: String {
        switch self {
        case .loaded: String(localized: "Scheduled")
        case .running: String(localized: "Running")
        case .disabled: String(localized: "Turned off")
        case .unscheduled: String(localized: "Not scheduled")
        }
    }
}

extension JobSnapshot {
    /// Colour of the card edge and sidebar marker: running, needs attention, or quiet.
    var tint: Color {
        if isRunning { return .blue }
        if loadState == .disabled { return .secondary.opacity(0.4) }
        if lastRun == nil, attention == .ok { return .secondary.opacity(0.4) }
        return attention == .ok ? (lastRun?.outcome.color ?? .green) : attention.color
    }

    /// One short line: what needs saying, otherwise when it last ran.
    func statusLine(now: Date) -> String {
        if isRunning { return String(localized: "Running…") }
        if definitionError != nil { return String(localized: "job.json is invalid") }
        if schedulingError != nil { return String(localized: "Not scheduled") }
        if !missingRequirements.isEmpty {
            return String(localized: "Missing: \(missingRequirements.joined(separator: ", "))")
        }
        switch loadState {
        case .disabled: return String(localized: "Turned off")
        case .loaded, .running, .unscheduled: break
        }
        guard let last = lastRun else { return String(localized: "Never run") }
        if last.outcome != .ok, let summary = last.summary { return summary }
        return Fmt.relative(last.endedAt, now: now)
    }
}

/// The last runs as small coloured squares, oldest on the left; empty slots are faint.
struct RunStrip: View {
    let outcomes: [Outcome?]
    var cell: CGFloat = 7

    var body: some View {
        HStack(spacing: 2) {
            // Fixed-length positional strip: position is the identity.
            ForEach(outcomes.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: cell / 4)
                    .fill(outcomes[index]?.color ?? Color.secondary.opacity(0.18))
                    .frame(width: cell, height: cell)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "Recent runs: \(outcomes.compactMap { $0?.label }.joined(separator: ", "))"))
    }
}

struct OutcomeBadge: View {
    let outcome: Outcome

    var body: some View {
        Label(outcome.label, systemImage: outcome.symbol)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(outcome.color)
            .font(.callout.weight(.medium))
    }
}

