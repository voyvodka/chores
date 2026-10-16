import Foundation

public enum LoadState: String, Equatable, Sendable {
    /// Scheduled by the Chores scheduler.
    case loaded
    case running
    /// Turned off in `settings.json`.
    case disabled
    /// Skipped by the scheduler: `schedulingError` or `definitionError` says why.
    case unscheduled
}

/// Everything the app shows about one job, gathered in one pass.
public struct JobSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var definition: JobDefinition?
    /// Set when `job.json` exists but cannot be read or is invalid.
    public var definitionError: String?
    /// Set when the definition is valid but the scheduler still will not start the job.
    public var schedulingError: String?
    /// Oldest first.
    public var runs: [RunRecord]
    public var running: RunningMarker?
    public var loadState: LoadState
    public var nextRun: NextRun?
    public var missingRequirements: [String] = []

    public init(id: String, label: String, definition: JobDefinition?, definitionError: String?, runs: [RunRecord],
                running: RunningMarker?, loadState: LoadState, nextRun: NextRun?) {
        self.id = id
        self.label = label
        self.definition = definition
        self.definitionError = definitionError
        self.runs = runs
        self.running = running
        self.loadState = loadState
        self.nextRun = nextRun
    }

    public var title: String { definition?.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? id }
    public var lastRun: RunRecord? { runs.last }
    public var isRunning: Bool { running != nil || loadState == .running }

    /// What this job contributes to the menu-bar icon. A disabled job contributes nothing; a broken
    /// definition fails; a missing required command is a warning.
    public var attention: Outcome {
        if definitionError != nil || schedulingError != nil { return .fail }
        if loadState == .disabled { return .ok }
        if !missingRequirements.isEmpty { return .warn }
        return lastRun?.outcome ?? .ok
    }
}

public enum JobOverview {
    public static func load(store: JobStore, now: Date = Date()) -> [JobSnapshot] {
        let disabled = store.disabledJobs()
        let state = store.schedulerState()
        return store.jobIDs().map { id in
            snapshot(id: id, store: store, disabled: disabled.contains(id), schedulerState: state, now: now)
        }
    }

    public static func snapshot(id: String, store: JobStore, disabled: Bool, schedulerState: SchedulerState = SchedulerState(),
                                now: Date) -> JobSnapshot {
        var definition: JobDefinition?
        var definitionError: String?
        do {
            let loaded = try store.definition(id)
            let errors = JobStore.definitionErrors(loaded, folder: id)
            definition = loaded
            if !errors.isEmpty { definitionError = errors.joined(separator: "; ") }
        } catch {
            definitionError = "\(error)"
        }
        // The same two checks as `JobStore.schedulableDefinition`, which the scheduler uses.
        let schedulingError = definitionError == nil ? store.schedulingBlocker(id) : nil
        let schedulable = definitionError == nil && schedulingError == nil

        let runs = store.runs(id)
        let running = store.running(id)
        let loadState: LoadState = disabled ? .disabled : running != nil ? .running : schedulable ? .loaded : .unscheduled
        let nextRun = disabled || !schedulable ? nil
            : definition?.schedule.nextRun(after: now, lastRunEnd: schedulerState.intervalStart(for: id, lastRunEnd: runs.last?.endedAt))

        var snapshot = JobSnapshot(id: id, label: store.paths.label(for: id), definition: definition,
                                   definitionError: definitionError, runs: runs, running: running,
                                   loadState: loadState, nextRun: nextRun)
        snapshot.schedulingError = schedulingError
        if let definition {
            snapshot.missingRequirements = Requirements.missing(definition.requires ?? [],
                                                                path: RunEnvironment.path(for: definition))
        }
        return snapshot
    }

    public static let uncategorized = "other"

    /// Jobs grouped by category, categories in name order with uncategorized jobs last.
    public static func grouped(_ jobs: [JobSnapshot]) -> [(category: String, jobs: [JobSnapshot])] {
        let groups = Dictionary(grouping: jobs) { job in
            job.definition?.category?.trimmingCharacters(in: .whitespaces).lowercased(with: Locale(identifier: "tr_TR"))
                .nonEmpty ?? uncategorized
        }
        return groups.keys
            .sorted { lhs, rhs in
                if lhs == uncategorized { return false }
                if rhs == uncategorized { return true }
                return lhs.compare(rhs, locale: Locale(identifier: "tr_TR")) == .orderedAscending
            }
            .map { ($0, groups[$0] ?? []) }
    }

    public static func attention(of jobs: [JobSnapshot]) -> Outcome {
        jobs.map(\.attention).max() ?? .ok
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
