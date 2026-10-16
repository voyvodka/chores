import Foundation

/// Run now, turn off, turn on. Scheduling belongs to the Chores scheduler, so none of these touch
/// launchd; turning a job off is a line in `settings.json` the scheduler reads on every tick.
public struct JobActions: Sendable {
    public let store: JobStore
    /// The `chores` executable to start runs with.
    public let runner: URL

    public init(store: JobStore, runner: URL? = nil) {
        self.store = store
        self.runner = runner ?? store.paths.runnerExecutable
    }

    public func runNow(_ id: String) throws {
        let job = try store.validDefinition(id)
        try Self.start(job: job, runner: runner, paths: store.paths, trigger: .manual)
    }

    /// Asks the run's runner to stop it, as Ctrl-C would: the runner stops the job's processes and
    /// records the run as stopped by the user. Returns once the signal is sent, not when the run ends.
    public func stop(_ id: String) throws {
        guard let marker = store.running(id), Self.isRunner(marker.pid) else { throw ChoresError.notRunning(id) }
        guard kill(marker.pid, SIGINT) == 0 else { throw ChoresError.notRunning(id) }
    }

    /// A marker's pid can be reused by an unrelated process of this user within the same boot.
    static func isRunner(_ pid: Int32) -> Bool {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return false }
        return String(cString: name) == "chores"
    }

    public func turnOff(_ id: String) throws { try store.setDisabled(id, true) }
    public func turnOn(_ id: String) throws { try store.setDisabled(id, false) }

    /// Deletes runs from the history with their logs and in-folder reports; `nil` deletes them all.
    @discardableResult
    public func deleteRuns(_ id: String, runIDs: Set<String>?) throws -> Int {
        _ = try store.definition(id)
        return try store.deleteRuns(id, runIDs: runIDs ?? Set(store.runs(id).map(\.id)))
    }

    /// Set by `start`: the runner writes the run id to this file once the job is running.
    public static let startedFileVariable = "CHORES_STARTED_FILE"

    /// Starts a run like `spawn`, then waits until the runner reports that the job is running. A
    /// refusal (the job is already running) or a runner that dies before the job starts is thrown,
    /// with what the runner wrote to stderr, instead of vanishing with the detached runner.
    @discardableResult
    public static func start(job: JobDefinition, runner: URL, paths: ChoresPaths, trigger: Trigger,
                             confirmWithin timeout: TimeInterval = 10) throws -> Process {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "chores-start-\(UUID().uuidString)")
        let startedURL = scratch.appendingPathExtension("started")
        let errorURL = scratch.appendingPathExtension("err")
        // A file rather than a pipe: once this caller is gone, a pipe would turn the runner's next
        // write to stderr into SIGPIPE.
        guard fm.createFile(atPath: errorURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        defer {
            try? fm.removeItem(at: startedURL)
            try? fm.removeItem(at: errorURL)
        }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let process = try spawn(job: job, runner: runner, paths: paths, trigger: trigger, errors: errors,
                                environment: [startedFileVariable: startedURL.path])
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fm.fileExists(atPath: startedURL.path) { return process }
            if !process.isRunning {
                // A short job can start and finish between two polls.
                if fm.fileExists(atPath: startedURL.path) { return process }
                var message = ((try? String(contentsOf: errorURL, encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if message.hasPrefix("chores: ") { message.removeFirst("chores: ".count) }
                throw ChoresError.startFailed(job.id, message.nonEmpty ?? "the runner exited with status \(process.terminationStatus)")
            }
            usleep(50_000)
        }
        return process
    }

    /// Starts `chores run <id>` detached, with the environment every run of the job gets. The run
    /// outlives the caller; the runner records it. Use `start` to learn whether the job started.
    @discardableResult
    public static func spawn(job: JobDefinition, runner: URL, paths: ChoresPaths, trigger: Trigger,
                             errors: FileHandle = .nullDevice, environment extra: [String: String] = [:]) throws -> Process {
        let process = Process()
        process.executableURL = runner
        process.arguments = ["run", job.id]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in RunEnvironment.variables(for: job, paths: paths) {
            environment[key] = value
        }
        environment["CHORES_TRIGGER"] = trigger.rawValue
        environment.merge(extra) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        return process
    }
}

/// The environment of a job's runs: a predictable PATH and HOME, the test root when one is in
/// use, then the job's own variables.
public enum RunEnvironment {
    public static var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// The `PATH` a job's runs see: the default, unless the job overrides it.
    public static func path(for job: JobDefinition) -> String {
        job.environment?["PATH"] ?? defaultPath
    }

    public static func variables(for job: JobDefinition, paths: ChoresPaths) -> [String: String] {
        var environment: [String: String] = [
            "PATH": defaultPath,
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        if paths.customRoot { environment["CHORES_HOME"] = paths.root.path }
        for (key, value) in job.environment ?? [:] {
            environment[key] = value
        }
        return environment
    }
}
