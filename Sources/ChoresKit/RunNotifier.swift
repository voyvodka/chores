import Foundation

/// Decides which finished runs deserve a notification between two refreshes.
public enum RunNotifier {
    /// `previous` maps job id to the last run id seen at the previous refresh; `nil` means this is
    /// the first load, which never notifies. Every run after that one is considered, so a failure
    /// followed by a success between two refreshes is still notified. Runs that ended before
    /// `since` (app launch) are old news even for a job that appeared since the last refresh.
    public static func runsToNotify(previous: [String: String]?, current: [JobSnapshot],
                                    since: Date) -> [(job: JobSnapshot, run: RunRecord)] {
        guard let previous else { return [] }
        return current.flatMap { job -> [(job: JobSnapshot, run: RunRecord)] in
            guard let definition = job.definition else { return [] }
            return newRunIndices(job.runs, after: previous[job.id]).compactMap { index in
                let run = job.runs[index]
                guard run.endedAt > since, definition.notifyPolicy.shouldNotify(run.outcome),
                      !isRepeat(run, earlier: job.runs[..<index]) else { return nil }
                return (job, run)
            }
        }
    }

    /// Indices of the runs after `seen`. A seen run no longer in the history (pruned or rewritten)
    /// leaves only the last run, so old runs are never notified twice.
    static func newRunIndices(_ runs: [RunRecord], after seen: String?) -> Range<Int> {
        guard let seen, !seen.isEmpty else { return runs.indices }
        if let position = runs.lastIndex(where: { $0.id == seen }) { return (position + 1)..<runs.endIndex }
        return runs.isEmpty ? runs.indices : (runs.endIndex - 1)..<runs.endIndex
    }

    /// How often a problem that keeps coming back unchanged is notified again.
    public static let repeatInterval: TimeInterval = 3600

    /// A warn or fail with the same outcome and summary as the runs right before it is the same
    /// problem still going on. It is notified when it starts and then about once per
    /// `repeatInterval`, counted from its start, instead of on every run (a job checking every
    /// 20 minutes once reported one broken CI run 19 times in a night). Stateless: decided from
    /// the run history alone, so the app and the runner's fallback agree.
    public static func isRepeat(_ run: RunRecord, earlier: some BidirectionalCollection<RunRecord>) -> Bool {
        guard run.outcome != .ok, let previous = earlier.last, sameProblem(previous, run) else { return false }
        var start = previous
        for record in earlier.reversed() {
            guard sameProblem(record, run) else { break }
            start = record
        }
        func period(_ record: RunRecord) -> Int {
            Int(record.endedAt.timeIntervalSince(start.endedAt) / repeatInterval)
        }
        return period(run) == period(previous)
    }

    private static func sameProblem(_ a: RunRecord, _ b: RunRecord) -> Bool {
        a.outcome == b.outcome && a.summary == b.summary
    }

    public static func lastRunIDs(_ jobs: [JobSnapshot]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.lastRun?.id ?? "") })
    }
}
