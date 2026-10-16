import Foundation

/// The scheduler's private memory between ticks, persisted in `scheduler-state.json`.
public struct SchedulerState: Codable, Equatable, Sendable {
    /// When each job was last evaluated; calendar runs are due between this and now.
    public var lastChecked: [String: Date] = [:]
    /// When the scheduler first saw a job; an interval job that never ran counts from here.
    public var firstSeen: [String: Date] = [:]
    /// Boot session in which each `runAtLoad` job last fired, so it fires once per boot.
    public var loadFiredBoot: [String: String] = [:]
    /// The last tick at which each job was turned off.
    public var lastSeenDisabled: [String: Date] = [:]

    public init() {}

    // Synthesized decoding ignores the defaults above: a state file written before a field existed
    // would fail to decode and reset everything, re-firing every `runAtLoad` job.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastChecked = try container.decodeIfPresent([String: Date].self, forKey: .lastChecked) ?? [:]
        firstSeen = try container.decodeIfPresent([String: Date].self, forKey: .firstSeen) ?? [:]
        loadFiredBoot = try container.decodeIfPresent([String: String].self, forKey: .loadFiredBoot) ?? [:]
        lastSeenDisabled = try container.decodeIfPresent([String: Date].self, forKey: .lastSeenDisabled) ?? [:]
    }

    /// Where a job's interval counts from: the end of its last run, or when the scheduler first saw
    /// it, or when it was last seen turned off if that is later. Time spent off is skipped, not
    /// caught up, so a job turned back on waits one interval. The app's next-run time uses this too.
    public func intervalStart(for id: String, lastRunEnd: Date?) -> Date? {
        [lastRunEnd ?? firstSeen[id], lastSeenDisabled[id]].compactMap { $0 }.max()
    }

    /// Drops what the scheduler remembers about jobs whose folder is gone, so a job re-created
    /// under the same id starts fresh instead of catching up from the old one's dates.
    public mutating func forget(allExcept ids: Set<String>) {
        lastChecked = lastChecked.filter { ids.contains($0.key) }
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        loadFiredBoot = loadFiredBoot.filter { ids.contains($0.key) }
        lastSeenDisabled = lastSeenDisabled.filter { ids.contains($0.key) }
    }
}

public struct SchedulerHeartbeat: Codable, Equatable, Sendable {
    public var pid: Int32
    public var tick: Date

    public init(pid: Int32, tick: Date) {
        self.pid = pid
        self.tick = tick
    }

    /// The scheduler ticks every 15 s; three missed ticks means it is not running.
    public func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(tick) < 90 }
}

/// Decides which jobs are due. Pure, so the rules are tested without time passing.
///
/// Semantics follow launchd, which the scheduler replaced: a calendar time missed while the Mac
/// slept runs once on wake (never once per missed occurrence); an interval counts from the end of
/// the previous run; `runAtLoad` runs once per boot (a log out and back in does not repeat it).
/// A calendar time that comes while the job is already running is skipped, not queued: the run in
/// progress started around then anyway, and running again right after it would repeat its work.
public enum Scheduler {
    public struct Input: Sendable {
        public var jobs: [JobDefinition]
        public var lastRunEnd: [String: Date]
        public var disabled: Set<String>
        public var running: Set<String>

        public init(jobs: [JobDefinition], lastRunEnd: [String: Date], disabled: Set<String>, running: Set<String>) {
            self.jobs = jobs
            self.lastRunEnd = lastRunEnd
            self.disabled = disabled
            self.running = running
        }
    }

    public struct Plan: Equatable, Sendable {
        public var due: [String] = []
        /// Jobs whose calendar time came while they were running.
        public var skipped: [String] = []
    }

    public static func due(_ input: Input, state: inout SchedulerState, now: Date, boot: String,
                           calendar: Calendar = .current) -> [String] {
        plan(input, state: &state, now: now, boot: boot, calendar: calendar).due
    }

    public static func plan(_ input: Input, state: inout SchedulerState, now: Date, boot: String,
                            calendar: Calendar = .current) -> Plan {
        var plan = Plan()
        for job in input.jobs where job.validationErrors().isEmpty {
            let id = job.id
            let checkedSince = state.lastChecked[id] ?? now
            state.lastChecked[id] = now
            if state.firstSeen[id] == nil { state.firstSeen[id] = now }
            // Disabled time is skipped, not caught up: turning a job back on must not fire a backlog.
            if input.disabled.contains(id) {
                state.lastSeenDisabled[id] = now
                if job.runAtLoad == true { state.loadFiredBoot[id] = boot }
                continue
            }
            if input.running.contains(id) {
                if job.schedule.calendar?.contains(where: { calendarTimeCame($0, since: checkedSince, now: now, calendar) }) == true {
                    plan.skipped.append(id)
                }
                continue
            }

            var isDue = false
            if job.runAtLoad == true, state.loadFiredBoot[id] != boot {
                state.loadFiredBoot[id] = boot
                isDue = true
            }
            for entry in job.schedule.calendar ?? [] {
                if calendarTimeCame(entry, since: checkedSince, now: now, calendar) { isDue = true }
            }
            if let interval = job.schedule.intervalSeconds {
                let base = state.intervalStart(for: id, lastRunEnd: input.lastRunEnd[id]) ?? now
                if base.addingTimeInterval(TimeInterval(interval)) <= now { isDue = true }
            }
            if isDue { plan.due.append(id) }
        }
        return plan
    }

    private static func calendarTimeCame(_ entry: CalendarEntry, since: Date, now: Date, _ calendar: Calendar) -> Bool {
        entry.nextDate(after: since, calendar: calendar).map { $0 <= now } ?? false
    }

    public static let currentBoot = bootSession()

    /// Identifies the current boot, so `runAtLoad` fires again after a restart.
    public static func bootSession() -> String {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 else { return "unknown" }
        return "\(boottime.tv_sec)"
    }
}
