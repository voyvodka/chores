import AppKit
import ChoresKit
import Foundation

let usage = """
usage: chores <command> [arguments]

  run <id>          Run a job now in this terminal and record the run. Exits 0 when the run is
                    ok, 1 on fail (including a timeout or a stop), 3 on warn, and 2 when no
                    run was started (also when the job is already running)
  install <id>      Validate job.json and hand the job to the scheduler
  uninstall <id>    Stop scheduling the job; the job folder is kept
  start <id>        Start a run now in the background, recorded as manual (the app's button);
                    fails when the job is already running or the run does not start
  disable <id>      Stop scheduling the job until enabled again
  enable <id>       Schedule a disabled job again
  retire <label>    Unload a pre-Chores launch agent and move its plist to the retired folder
  validate <id>     Check job.json without installing
  delete-runs <id> <run-id>... | --all
                    Delete runs from the history with their logs and the reports in the job folder
  list              Jobs, their state and last run, and whether the scheduler is running
  scheduler         Run the scheduler (started by the agent inside Chores.app)
  paths             Print where jobs and state live
"""

let paths = ChoresPaths.current()
let store = JobStore(paths: paths)
let launchctl = Launchctl()

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("chores: \(message)\n".utf8))
    exit(code)
}

func requireArgument(_ args: [String], _ name: String) -> String {
    guard args.count >= 3 else { fail("missing <\(name)>\n\n\(usage)") }
    return args[2]
}

/// Job ids become path components, so reject anything else before use.
func requireJobID(_ args: [String]) -> String {
    let id = requireArgument(args, "id")
    guard JobDefinition.isValidID(id) else { fail("invalid job id \"\(id)\" (expected [a-z0-9][a-z0-9-]*)") }
    return id
}

/// The app delivers its own notifications for new runs; this is the fallback when it is not open.
func notifyIfNeeded(_ job: JobDefinition, _ record: RunRecord) {
    guard job.notifyPolicy.shouldNotify(record.outcome) else { return }
    let earlier = store.runs(job.id).filter { $0.id != record.id }
    guard !RunNotifier.isRepeat(record, earlier: earlier) else { return }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: ChoresPaths.appBundleIdentifier).isEmpty else {
        return
    }
    let title = "\(job.title) · \(record.outcome.rawValue)"
    let message = record.summary ?? "Finished in \(Int(record.durationSeconds))s"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    // Passing text as argv avoids AppleScript string escaping entirely.
    process.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title (item 2 of argv)",
                         "-e", "end run", message, title]
    try? process.run()
    process.waitUntilExit()
}

func currentTrigger(for id: String) -> Trigger {
    let env = ProcessInfo.processInfo.environment
    if let raw = env["CHORES_TRIGGER"], let trigger = Trigger(rawValue: raw) { return trigger }
    return env["XPC_SERVICE_NAME"] == paths.label(for: id) ? .launchd : .manual
}

func runCommand(_ id: String) -> Never {
    let trigger = currentTrigger(for: id)
    do {
        let job = try store.definition(id)
        let startedFile = ProcessInfo.processInfo.environment[JobActions.startedFileVariable]
        let record = try JobRunner(store: store).run(jobID: id, trigger: trigger, forwardSignals: true) { runID in
            guard let startedFile else { return }
            try? Data(runID.utf8).write(to: URL(fileURLWithPath: startedFile), options: .atomic)
        }
        if trigger == .manual {
            print("\(record.outcome.rawValue) \(record.summary ?? "") (\(String(format: "%.1f", record.durationSeconds))s)")
            print("log: \(paths.jobDirectory(id).appending(path: record.log).path)")
            if let report = record.report { print("report: \(report)") }
        }
        notifyIfNeeded(job, record)
        exit(record.outcome.exitStatus)
    } catch {
        fail("\(error)")
    }
}

func validate(_ id: String) -> JobDefinition {
    do {
        return try store.validDefinition(id)
    } catch let error as ChoresError {
        fail(error.description)
    } catch {
        fail("job.json of \"\(id)\" could not be read: \(error)")
    }
}

/// Jobs used to be one launch agent each. Removing that agent is part of handing a job to the
/// scheduler; until then the scheduler leaves the job alone so it never runs twice.
func removeLegacyAgent(_ id: String) {
    let plist = paths.plistURL(for: id)
    guard FileManager.default.fileExists(atPath: plist.path) else { return }
    launchctl.bootout(paths.label(for: id))
    try? FileManager.default.removeItem(at: plist)
    print("removed per-job launch agent \(paths.label(for: id))")
}

func schedulerLine() -> String {
    guard let beat = store.heartbeat(), beat.isFresh() else {
        return "scheduler: NOT RUNNING — open Chores.app once (it registers the scheduler)"
    }
    return "scheduler: running (pid \(beat.pid), last tick \(beat.tick.formatted(date: .omitted, time: .standard)))"
}

func install(_ id: String) {
    let job = validate(id)
    if store.running(id) != nil {
        fail("\(id) is running right now; install again when the run has finished")
    }
    do {
        try FileManager.default.createDirectory(at: paths.logsDirectory(id), withIntermediateDirectories: true)
        try store.setDisabled(id, false)
    } catch {
        fail("\(error)")
    }
    removeLegacyAgent(id)
    print("installed \(id)")
    let intervalStart = store.schedulerState().intervalStart(for: id, lastRunEnd: store.lastRun(id)?.endedAt)
    if let next = job.schedule.nextRun(after: Date(), lastRunEnd: intervalStart) {
        print("next run: \(next.date.formatted(date: .abbreviated, time: .shortened))")
    } else if job.schedule.isManual {
        print("next run: on demand only")
    } else {
        print("next run: one interval after the scheduler first sees it")
    }
    print(schedulerLine())
}

func uninstall(_ id: String) {
    do {
        try store.setDisabled(id, true)
    } catch {
        fail("\(error)")
    }
    removeLegacyAgent(id)
    print("\(id) is no longer scheduled; job folder kept at \(paths.jobDirectory(id).path)")
}

func retire(_ label: String) {
    guard Launchctl.isValidLabel(label) else { fail("invalid label \"\(label)\"") }
    if label.hasPrefix(ChoresPaths.labelPrefix + ".") || label.hasPrefix(ChoresPaths.testLabelPrefix + ".") {
        fail("\(label) is a Chores job; use `chores uninstall` instead")
    }
    if label.hasPrefix("com.apple.") { fail("refusing to retire a system agent (\(label))") }
    let fm = FileManager.default
    let source = paths.launchAgentsDirectory.appending(path: "\(label).plist")
    // Only agents defined by a plist in ~/Library/LaunchAgents are retired; a typo must not unload
    // some other loaded service.
    guard fm.fileExists(atPath: source.path) else { fail("no plist at \(source.path); nothing retired") }
    launchctl.bootout(label)
    do {
        try fm.createDirectory(at: paths.retiredDirectory, withIntermediateDirectories: true)
        var destination = paths.retiredDirectory.appending(path: "\(label).plist")
        if fm.fileExists(atPath: destination.path) {
            destination = paths.retiredDirectory.appending(path: "\(label).\(Int(Date().timeIntervalSince1970)).plist")
        }
        try fm.moveItem(at: source, to: destination)
        print("retired \(label) -> \(destination.path)")
        print("undo: mv \"\(destination.path)\" \"\(source.path)\" && launchctl bootstrap \(launchctl.domain) \"\(source.path)\"")
    } catch {
        fail("\(error)")
    }
}

func list() {
    print(schedulerLine())
    let ids = store.jobIDs()
    guard !ids.isEmpty else {
        print("no jobs in \(paths.jobsDirectory.path)")
        return
    }
    let disabled = store.disabledJobs()
    for id in ids {
        let state = disabled.contains(id) ? "disabled"
            : store.running(id) != nil ? "running"
            : store.schedulableDefinition(id) == nil ? "not scheduled" : "scheduled"
        var line = "\(id)  [\(state)]"
        if let last = store.lastRun(id) {
            line += "  last: \(last.outcome.rawValue) \(last.endedAt.formatted(date: .abbreviated, time: .shortened))"
            if let summary = last.summary { line += " — \(summary)" }
        } else {
            line += "  last: never"
        }
        print(line)
    }
}

// MARK: - Scheduler

final class SchedulerLog {
    private let url: URL
    init(url: URL) { self.url = url }

    func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        // Keep one small file: past 1 MB it starts over.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// A scheduled runner's stderr, so a run refused or broken before it starts leaves a line in the log.
func schedulerLogForRunners() -> FileHandle {
    let fd = open(paths.schedulerLogURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : .nullDevice
}

/// A second scheduler (one started by hand next to the agent) would start every due job twice.
func holdSchedulerLock() {
    let fd = open(paths.root.appending(path: "scheduler.lock").path, O_RDWR | O_CREAT, 0o644)
    guard fd >= 0 else { fail("cannot open the scheduler lock in \(paths.root.path)") }
    // Held until the process exits; the descriptor is deliberately never closed.
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { fail("another scheduler is already running", code: 1) }
}

func runScheduler() -> Never {
    try? FileManager.default.createDirectory(at: paths.jobsDirectory, withIntermediateDirectories: true)
    holdSchedulerLock()
    let log = SchedulerLog(url: paths.schedulerLogURL)
    let boot = Scheduler.currentBoot
    guard let me = Bundle.main.executableURL else { fail("cannot resolve own executable") }
    var children: [Process] = []
    // Kept in memory: re-reading it every tick would re-fire due jobs whenever a save failed.
    var state = store.schedulerState()
    var lastSaveFailed = false
    log.write("scheduler started pid=\(getpid()) boot=\(boot) runner=\(me.path)")

    while true {
        // No run loop drains the main thread's pool, so without this every Foundation object
        // a tick autoreleases (file data, URLs, strings) stays alive for the life of the process.
        autoreleasepool {
            let now = Date()
            store.writeHeartbeat(SchedulerHeartbeat(pid: getpid(), tick: now))

            // A job still owned by its old launch agent is left to it, so it never runs twice.
            let jobs = store.jobIDs().compactMap(store.schedulableDefinition)
            let ids = jobs.map(\.id)
            let input = Scheduler.Input(
                jobs: jobs,
                lastRunEnd: Dictionary(uniqueKeysWithValues: ids.compactMap { id in store.lastRun(id).map { (id, $0.endedAt) } }),
                disabled: store.disabledJobs(),
                running: Set(ids.filter { store.running($0) != nil })
            )
            state.forget(allExcept: Set(store.jobIDs()))
            let due = Scheduler.due(input, state: &state, now: now, boot: boot)
            do {
                try store.saveSchedulerState(state)
                lastSaveFailed = false
            } catch {
                if !lastSaveFailed { log.write("could not save scheduler state: \(error)") }
                lastSaveFailed = true
            }

            for id in due {
                guard let job = jobs.first(where: { $0.id == id }) else { continue }
                do {
                    children.append(try JobActions.spawn(job: job, runner: me, paths: paths, trigger: .scheduled,
                                                         errors: schedulerLogForRunners()))
                    log.write("started \(id)")
                } catch {
                    log.write("could not start \(id): \(error)")
                }
            }
            children.removeAll { !$0.isRunning }
        }
        sleep(15)
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "run": runCommand(requireJobID(args))
case "install": install(requireJobID(args))
case "uninstall": uninstall(requireJobID(args))
case "retire": retire(requireArgument(args, "label"))
case "start", "disable", "enable":
    let id = requireJobID(args)
    let actions = JobActions(store: store)
    do {
        switch args[1] {
        case "start": try actions.runNow(id)
        case "disable": try actions.turnOff(id)
        default: try actions.turnOn(id)
        }
    } catch {
        fail("\(error)")
    }
    print("\(args[1]) \(id): ok")
case "delete-runs":
    let id = requireJobID(args)
    let selected = Array(args.dropFirst(3))
    guard !selected.isEmpty else { fail("missing <run-id>... or --all\n\n\(usage)") }
    do {
        let count = try JobActions(store: store).deleteRuns(id, runIDs: selected == ["--all"] ? nil : Set(selected))
        print("deleted \(count) run(s) of \(id)")
    } catch {
        fail("\(error)")
    }
case "validate":
    let id = requireJobID(args)
    let job = validate(id)
    var warnings = job.validationWarnings()
    let missing = Requirements.missing(job.requires ?? [], path: RunEnvironment.path(for: job))
    if !missing.isEmpty { warnings.append("required commands not found on the job's PATH: \(missing.joined(separator: ", "))") }
    print("\(id): ok\(warnings.isEmpty ? "" : " with \(warnings.count) warning(s)")")
    for warning in warnings { print("  warning: \(warning)") }
case "list": list()
case "scheduler": runScheduler()
case "paths":
    print("jobs:      \(paths.jobsDirectory.path)")
    print("settings:  \(paths.settingsURL.path)")
    print("scheduler: \(paths.schedulerLogURL.path)")
    print("runner:    \(paths.runnerExecutable.path)")
case "-h", "--help", "help": print(usage)
default: fail("unknown command\n\n\(usage)")
}
