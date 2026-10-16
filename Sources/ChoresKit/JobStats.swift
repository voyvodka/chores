import Foundation

/// Figures shown in the job window's summary tiles, over the most recent runs.
public struct JobStats: Equatable, Sendable {
    public var runCount: Int
    /// Share of `ok` runs, 0...1; `nil` without runs.
    public var successRate: Double?
    public var averageDuration: Double?
    public var failures: Int

    public init(runs: [RunRecord], window: Int = 30) {
        let recent = runs.suffix(window)
        runCount = runs.count
        failures = recent.filter { $0.outcome == .fail }.count
        if recent.isEmpty {
            successRate = nil
            averageDuration = nil
        } else {
            successRate = Double(recent.filter { $0.outcome == .ok }.count) / Double(recent.count)
            averageDuration = recent.map(\.durationSeconds).reduce(0, +) / Double(recent.count)
        }
    }

    /// The last `count` outcomes, oldest first, padded at the front with `nil` for missing runs.
    public static func strip(_ runs: [RunRecord], count: Int = 10) -> [Outcome?] {
        let outcomes = runs.suffix(count).map { Optional($0.outcome) }
        return Array(repeating: nil, count: count - outcomes.count) + outcomes
    }
}
