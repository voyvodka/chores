import Foundation

public enum Outcome: String, Codable, Sendable, CaseIterable, Comparable {
    case ok, warn, fail

    private var severity: Int {
        switch self {
        case .ok: 0
        case .warn: 1
        case .fail: 2
        }
    }

    public static func < (lhs: Outcome, rhs: Outcome) -> Bool { lhs.severity < rhs.severity }

    /// Exit status of `chores run` for a recorded run. 2 is left to runs that never started.
    public var exitStatus: Int32 {
        switch self {
        case .ok: 0
        case .fail: 1
        case .warn: 3
        }
    }
}

public enum Trigger: String, Codable, Sendable {
    /// Started by the Chores scheduler.
    case scheduled
    case manual
    /// Started by a per-job launchd agent, before the scheduler replaced them. Only in old history.
    case launchd

    public var isScheduled: Bool { self != .manual }
}

/// One line of a job's `runs.jsonl`.
public struct RunRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: Double
    public var exitCode: Int32
    /// Set when the process was killed by a signal; `exitCode` then holds the signal number.
    public var signal: Bool?
    public var timedOut: Bool?
    public var outcome: Outcome
    public var summary: String?
    /// Absolute path of the report this run produced, if any.
    public var report: String?
    /// Log file path relative to the job folder.
    public var log: String
    public var trigger: Trigger
    /// The job's `version` when this run started.
    public var jobVersion: String?
    /// Stopped on purpose (Stop in the app, `chores stop`, Ctrl-C), which is never notified.
    public var stoppedByUser: Bool?

    public init(id: String, startedAt: Date, endedAt: Date, durationSeconds: Double, exitCode: Int32,
                signal: Bool? = nil, timedOut: Bool? = nil, outcome: Outcome, summary: String? = nil,
                report: String? = nil, log: String, trigger: Trigger, jobVersion: String? = nil,
                stoppedByUser: Bool? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.exitCode = exitCode
        self.signal = signal
        self.timedOut = timedOut
        self.outcome = outcome
        self.summary = summary
        self.report = report
        self.log = log
        self.trigger = trigger
        self.jobVersion = jobVersion
        self.stoppedByUser = stoppedByUser
    }
}

/// `running.json`, present while a run is in progress.
public struct RunningMarker: Codable, Equatable, Sendable {
    public var runID: String
    public var pid: Int32
    public var startedAt: Date
    public var trigger: Trigger
    /// Boot session the run started in; absent in markers written before it was recorded.
    public var boot: String?

    public init(runID: String, pid: Int32, startedAt: Date, trigger: Trigger, boot: String? = Scheduler.currentBoot) {
        self.runID = runID
        self.pid = pid
        self.startedAt = startedAt
        self.trigger = trigger
        self.boot = boot
    }

    /// A runner that crashed leaves its marker behind; only a live pid counts as running. EPERM is
    /// not accepted: the runner is always this user's process, so EPERM means the pid was reused.
    /// A marker from an earlier boot is dead even if its pid is alive again (power loss mid-run).
    public var isAlive: Bool {
        if let boot, boot != Scheduler.currentBoot { return false }
        return kill(pid, 0) == 0
    }
}
