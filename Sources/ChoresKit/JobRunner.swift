import Foundation

/// Executes one run of a job and records it. This is the body of `chores run`.
public struct JobRunner: Sendable {
    public let store: JobStore
    public let now: @Sendable () -> Date

    public init(store: JobStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    private var paths: ChoresPaths { store.paths }

    /// - Parameter forwardSignals: when true (the CLI), SIGTERM/SIGINT/SIGHUP sent to this process
    ///   are passed to the job's process group and the run is still recorded. launchd sends
    ///   SIGTERM on unload, logout and reinstall, and would otherwise orphan the job.
    /// - Parameter onStart: called with the run id once the job's process is running; a caller
    ///   that started the runner learns from it that the run was not refused.
    public func run(jobID: String, trigger: Trigger, forwardSignals: Bool = false,
                    onStart: ((String) -> Void)? = nil) throws -> RunRecord {
        let job = try store.validDefinition(jobID)
        // Taken before anything is written, so a refused run leaves no log, marker or record behind.
        let runLock = try Self.acquireRunLock(paths.runLockURL(jobID), jobID: jobID)
        defer { close(runLock) }

        let fm = FileManager.default
        let jobDir = paths.jobDirectory(jobID)
        let startedAt = now()
        let runID = Self.makeRunID(startedAt)
        try fm.createDirectory(at: paths.logsDirectory(jobID), withIntermediateDirectories: true)
        let logRelative = RunRecord.logPath(runID: runID)
        let logURL = jobDir.appending(path: logRelative)
        fm.createFile(atPath: logURL.path, contents: nil)
        let resultURL = fm.temporaryDirectory.appending(path: "chores-\(jobID)-\(runID).result")
        defer { try? fm.removeItem(at: resultURL) }

        // The same PATH and HOME whoever starts the run, so a run from a terminal behaves like a
        // scheduled one.
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in RunEnvironment.variables(for: job, paths: paths) {
            environment[key] = value
        }
        environment["CHORES_JOB_ID"] = jobID
        environment["CHORES_JOB_DIR"] = jobDir.path
        environment["CHORES_RUN_ID"] = runID
        environment["CHORES_RESULT"] = resultURL.path
        environment[JobActions.startedFileVariable] = nil
        let reportDir = job.reportDirectoryURL(in: jobDir)
        if let reportDir {
            try? fm.createDirectory(at: reportDir, withIntermediateDirectories: true)
            environment["CHORES_REPORT_DIR"] = reportDir.path
        }

        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = job.command
        process.currentDirectoryURL = jobDir
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        let timedOut = Flag()
        let stoppedBy = Flag()
        let childPID = Flag()
        // Installed before the job starts, so a signal can never kill the runner unrecorded.
        let forwarder = forwardSignals ? SignalForwarder() : nil
        forwarder?.start { signal in
            stoppedBy.set(Int(signal))
            if let pid = childPID.value {
                kill(-pid_t(pid), signal)
                Self.killIfStillRunning(group: -pid_t(pid), after: 3)
            }
        }
        defer { forwarder?.stop() }

        let sleep = SleepMeter()
        let assertion = IdleSleepAssertion(jobID: jobID, limit: TimeInterval(job.timeoutSeconds ?? 3600) + 60)
        defer { assertion.release() }
        try process.run()
        // The job leads its own process group, so signalling -pid reaches everything it started.
        let group = -process.processIdentifier
        childPID.set(Int(process.processIdentifier))
        if let early = stoppedBy.value {
            kill(group, Int32(early))
            Self.killIfStillRunning(group: group, after: 3)
        }
        try? store.setRunning(RunningMarker(runID: runID, pid: ProcessInfo.processInfo.processIdentifier,
                                            startedAt: startedAt, trigger: trigger), for: jobID)
        defer { store.clearRunning(jobID, runID: runID) }
        onStart?(runID)

        if let timeout = job.timeoutSeconds {
            // DispatchTime stops while the Mac sleeps, so the timeout counts awake time, as `awakeSeconds` does.
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) { [process] in
                guard process.isRunning else { return }
                timedOut.set(1)
                kill(group, SIGTERM)
                Self.killIfStillRunning(group: group, after: Self.timeoutGrace)
            }
        }
        process.waitUntilExit()
        // What the job leaves in its group (`cmd &`, an agent CLI that ignores SIGTERM) must not
        // outlive the run: it would keep spending quota and overlap the next run.
        if kill(group, 0) == 0 {
            if timedOut.value == nil, stoppedBy.value == nil {
                try? logHandle.write(contentsOf: Data("chores: the job exited; stopping the processes it left running\n".utf8))
            }
            kill(group, SIGTERM)
            Self.reap(group: group, grace: stoppedBy.value != nil ? 3 : Self.timeoutGrace)
        }

        let endedAt = now()
        let signal = process.terminationReason == .uncaughtSignal
        // Lossy decoding: one invalid byte must not discard the outcome the script reported.
        let result = (try? Data(contentsOf: resultURL)).map { ResultFile.parse(String(decoding: $0, as: UTF8.self)) }
        var (outcome, summary) = ResultFile.resolve(exitCode: process.terminationStatus, signal: signal,
                                                    timedOut: timedOut.value != nil, timeoutSeconds: job.timeoutSeconds,
                                                    result: result)
        // SIGINT comes from a person (Stop, `chores stop`, Ctrl-C); launchd and the scheduler send SIGTERM.
        let byUser = stoppedBy.value == Int(SIGINT) && timedOut.value == nil
        if let stopped = stoppedBy.value, timedOut.value == nil {
            outcome = .fail
            summary = byUser ? "Stopped by the user"
                : "Stopped (signal \(stopped): the job was turned off or reinstalled, or the session ended)"
        }
        let report = resolveReport(result?.report, reportDir: reportDir, jobDir: jobDir, since: startedAt)

        let record = RunRecord(id: runID, startedAt: startedAt, endedAt: endedAt,
                               durationSeconds: endedAt.timeIntervalSince(startedAt),
                               exitCode: process.terminationStatus, signal: signal ? true : nil,
                               timedOut: timedOut.value != nil ? true : nil, outcome: outcome, summary: summary,
                               report: report, log: logRelative, trigger: trigger, jobVersion: job.version,
                               stoppedByUser: byUser ? true : nil, asleepSeconds: sleep.asleepSeconds)
        try store.append(record, to: jobID)
        store.prune(jobID)
        return record
    }

    /// An explicit `report` line wins; otherwise the newest file written into the report folder
    /// during this run.
    private func resolveReport(_ declared: String?, reportDir: URL?, jobDir: URL, since start: Date) -> String? {
        if let declared {
            let expanded = (declared as NSString).expandingTildeInPath
            return expanded.hasPrefix("/") ? expanded : jobDir.appending(path: expanded).path
        }
        guard let reportDir else { return nil }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: reportDir, includingPropertiesForKeys: keys)) ?? []
        // One second of slack: filesystem timestamps can land just before the recorded start.
        let threshold = start.addingTimeInterval(-1)
        return files
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= threshold else { return nil }
                return (url, modified)
            }
            .max { $0.1 < $1.1 }?
            .0.path
    }

    static func makeRunID(_ date: Date) -> String {
        let stamp = date.formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, dateTimeSeparator: .standard,
                                                           timeSeparator: .omitted, timeZone: .gmt))
        let suffix = String(UInt16.random(in: 0...UInt16.max), radix: 16)
        return "\(stamp)-\(String(repeating: "0", count: 4 - suffix.count))\(suffix)"
    }

    static let timeoutGrace: Double = 5

    /// O_CLOEXEC: a job's own processes must not inherit the lock and hold it past the run.
    ///
    /// A busy lock is retried for about a second before the run is refused. A process being spawned
    /// elsewhere in the same runner or scheduler holds a copy of every descriptor until its exec
    /// closes the CLOEXEC ones, so a lock released just now can look held for a few milliseconds
    /// (seen as a flaky "already running" in the tests). A job that really runs is still refused.
    static func acquireRunLock(_ url: URL, jobID: String, patience: Double = 1) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let deadline = Date().addingTimeInterval(patience)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK, Date() < deadline {
                usleep(50_000)
                continue
            }
            close(fd)
            if code == EWOULDBLOCK { throw ChoresError.alreadyRunning(jobID) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }

    /// SIGTERM can be trapped or ignored by the job's first process, and the runner waits for that
    /// process before it reaps the group; without this a stubborn job would run past its limit.
    static func killIfStillRunning(group: pid_t, after grace: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if kill(group, 0) == 0 { kill(group, SIGKILL) }
        }
    }

    /// Waits up to `grace` seconds for a process group to exit, then kills what is left.
    static func reap(group: pid_t, grace: Double) {
        let deadline = Date().addingTimeInterval(grace)
        while kill(group, 0) == 0, Date() < deadline {
            usleep(100_000)
        }
        if kill(group, 0) == 0 { kill(group, SIGKILL) }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?

    func set(_ value: Int) { lock.withLock { stored = value } }
    var value: Int? { lock.withLock { stored } }
}

/// Catches SIGTERM/SIGINT/SIGHUP for the duration of a run instead of dying from them.
private final class SignalForwarder: @unchecked Sendable {
    private static let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
    private var sources: [DispatchSourceSignal] = []

    func start(_ handler: @escaping @Sendable (Int32) -> Void) {
        for sig in Self.signals {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { handler(sig) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for sig in Self.signals { signal(sig, SIG_DFL) }
    }
}
