import Foundation

/// Filesystem layout shared by the runner, the app and the skill.
public struct ChoresPaths: Sendable, Equatable {
    public static let labelPrefix = "dev.voyvodka.chores"
    public static let testLabelPrefix = "dev.voyvodka.chores-test"
    public static let appBundleIdentifier = "dev.voyvodka.chores"
    /// The one background agent, embedded in Chores.app, that schedules every job.
    public static let schedulerLabel = "dev.voyvodka.chores.scheduler"

    public let root: URL
    public let labelPrefix: String
    public let launchAgentsDirectory: URL
    public let runnerExecutable: URL
    /// Set when `root` is not the default, so spawned runs find the same root.
    public let customRoot: Bool

    public init(root: URL, labelPrefix: String, launchAgentsDirectory: URL, runnerExecutable: URL, customRoot: Bool) {
        self.root = root
        self.labelPrefix = labelPrefix
        self.launchAgentsDirectory = launchAgentsDirectory
        self.runnerExecutable = runnerExecutable
        self.customRoot = customRoot
    }

    /// Resolves the layout from the environment. `CHORES_HOME` selects another root (a test root the
    /// scheduler never schedules) and switches labels to the test prefix, so a test job can never
    /// be mistaken for a real job's pre-Chores launch agent. `CHORES_RUNNER` overrides the runner.
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> ChoresPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let runner = environment["CHORES_RUNNER"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appending(path: ".local/bin/chores")
        let agents = home.appending(path: "Library/LaunchAgents")
        if let custom = environment["CHORES_HOME"], !custom.isEmpty {
            return ChoresPaths(root: URL(fileURLWithPath: custom), labelPrefix: testLabelPrefix,
                               launchAgentsDirectory: agents, runnerExecutable: runner, customRoot: true)
        }
        return ChoresPaths(root: home.appending(path: ".local/share/chores"), labelPrefix: labelPrefix,
                           launchAgentsDirectory: agents, runnerExecutable: runner, customRoot: false)
    }

    public var jobsDirectory: URL { root.appending(path: "jobs") }
    /// Written by the scheduler on every tick, so the app can tell whether it is alive.
    public var schedulerHeartbeatURL: URL { root.appending(path: "scheduler.json") }
    public var schedulerStateURL: URL { root.appending(path: "scheduler-state.json") }
    public var schedulerLogURL: URL { root.appending(path: "scheduler.log") }
    /// User intent shared by the CLI and the app: which jobs are turned off.
    public var settingsURL: URL { root.appending(path: "settings.json") }
    /// Where `chores retire` moves the plists of jobs replaced by a Chores job.
    public var retiredDirectory: URL { root.appending(path: "retired") }

    public func jobDirectory(_ id: String) -> URL { jobsDirectory.appending(path: id) }
    public func definitionURL(_ id: String) -> URL { jobDirectory(id).appending(path: "job.json") }
    public func runsURL(_ id: String) -> URL { jobDirectory(id).appending(path: "runs.jsonl") }
    /// One marker file per in-progress run.
    public func runningDirectory(_ id: String) -> URL { jobDirectory(id).appending(path: ".running") }
    public func logsDirectory(_ id: String) -> URL { jobDirectory(id).appending(path: "logs") }
    /// Held by the runner for the whole run, so a job never runs twice at once.
    public func runLockURL(_ id: String) -> URL { jobDirectory(id).appending(path: ".run.lock") }

    /// Label and plist of the job's pre-Chores launch agent, if one is still installed.
    public func label(for id: String) -> String { "\(labelPrefix).\(id)" }
    public func plistURL(for id: String) -> URL { launchAgentsDirectory.appending(path: "\(label(for: id)).plist") }
}
