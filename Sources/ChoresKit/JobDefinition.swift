import Foundation

/// Contents of a job's `job.json`. Written by the Claude Code skill, read by the runner and the app.
public struct JobDefinition: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// What the job does, in a sentence or two.
    public var summary: String
    /// argv, executed through `/usr/bin/env` with the job folder as working directory.
    public var command: [String]
    public var schedule: Schedule
    public var runAtLoad: Bool?
    public var timeoutSeconds: Int?
    public var environment: [String: String]?
    /// Folder the job writes reports into, relative to the job folder or absolute.
    public var reportDirectory: String?
    public var notify: NotifyPolicy?
    /// Human-readable description of what an agent inside the job may do.
    public var permissions: String?
    /// Free-form notes, typically the summary Claude Code gave when it set the job up.
    public var notes: [String]?
    public var createdBy: String?
    public var createdAt: Date?
    /// The job's own version, bumped whenever its script or definition changes. Each run records it.
    public var version: String?
    /// Newest first.
    public var changelog: [ChangelogEntry]?
    /// Groups jobs in the app: "watch", "maintenance", "sync", "report", or a word of the job's own.
    public var category: String?
    /// Commands the job needs on `PATH` (or absolute paths); missing ones make the job a warning.
    public var requires: [String]?
    /// Folder of the project the job belongs to, if any.
    public var project: String?
    public var links: [JobLink]?

    public init(id: String, title: String, summary: String, command: [String], schedule: Schedule,
                runAtLoad: Bool? = nil, timeoutSeconds: Int? = nil, environment: [String: String]? = nil,
                reportDirectory: String? = nil, notify: NotifyPolicy? = nil, permissions: String? = nil,
                notes: [String]? = nil, createdBy: String? = nil, createdAt: Date? = nil,
                version: String? = nil, changelog: [ChangelogEntry]? = nil, category: String? = nil,
                requires: [String]? = nil, project: String? = nil, links: [JobLink]? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.command = command
        self.schedule = schedule
        self.runAtLoad = runAtLoad
        self.timeoutSeconds = timeoutSeconds
        self.environment = environment
        self.reportDirectory = reportDirectory
        self.notify = notify
        self.permissions = permissions
        self.notes = notes
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.version = version
        self.changelog = changelog
        self.category = category
        self.requires = requires
        self.project = project
        self.links = links
    }

    public var projectURL: URL? {
        guard let project, !project.isEmpty else { return nil }
        return URL(fileURLWithPath: (project as NSString).expandingTildeInPath)
    }

    /// Problems worth surfacing that do not stop the job from being installed or run.
    public func validationWarnings() -> [String] {
        var warnings: [String] = []
        if version == nil { warnings.append("no version; add \"version\" and a \"changelog\" entry") }
        if let version, !(changelog ?? []).contains(where: { $0.version == version }) {
            warnings.append("changelog has no entry for version \(version)")
        }
        if category == nil { warnings.append("no category") }
        if let project = projectURL, !FileManager.default.fileExists(atPath: project.path) {
            warnings.append("project folder does not exist: \(project.path)")
        }
        return warnings
    }

    public var notifyPolicy: NotifyPolicy { notify ?? .problems }

    public func reportDirectoryURL(in jobDirectory: URL) -> URL? {
        guard let reportDirectory, !reportDirectory.isEmpty else { return nil }
        let expanded = (reportDirectory as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : jobDirectory.appending(path: expanded)
    }

    public func manualRunCommand() -> String { "chores run \(id)" }

    /// Problems that would make the job unrunnable or unsafe to install, empty when valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if !JobDefinition.isValidID(id) {
            errors.append("id must match [a-z0-9][a-z0-9-]* (got \"\(id)\")")
        }
        if title.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("title is empty") }
        if command.isEmpty || command[0].isEmpty { errors.append("command is empty") }
        if let t = timeoutSeconds, t <= 0 { errors.append("timeoutSeconds must be positive") }
        errors.append(contentsOf: schedule.validationErrors())
        return errors
    }

    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, !id.isEmpty, id.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first)
            && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public struct ChangelogEntry: Codable, Equatable, Sendable {
    public var version: String
    /// "YYYY-MM-DD", kept as text because `job.json` is hand-written.
    public var date: String?
    public var notes: [String]

    public init(version: String, date: String? = nil, notes: [String]) {
        self.version = version
        self.date = date
        self.notes = notes
    }
}

public struct JobLink: Codable, Equatable, Sendable {
    public var title: String
    /// A web URL or a local path (`~` allowed).
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }

    public var resolvedURL: URL? {
        if url.hasPrefix("/") || url.hasPrefix("~") {
            return URL(fileURLWithPath: (url as NSString).expandingTildeInPath)
        }
        return URL(string: url)
    }
}

/// Finds which of a job's required commands are missing, on the same `PATH` launchd gives it.
public enum Requirements {
    public static func missing(_ commands: [String], path: String) -> [String] {
        let dirs = path.split(separator: ":").map(String.init)
        let fm = FileManager.default
        return commands.filter { command in
            let expanded = (command as NSString).expandingTildeInPath
            if expanded.contains("/") { return !fm.isExecutableFile(atPath: expanded) }
            return !dirs.contains { fm.isExecutableFile(atPath: "\($0)/\(expanded)") }
        }
    }
}

public enum NotifyPolicy: String, Codable, Sendable, CaseIterable {
    /// Every run.
    case always
    /// Runs that end in `warn` or `fail`.
    case problems
    case never

    public func shouldNotify(_ outcome: Outcome) -> Bool {
        switch self {
        case .always: true
        case .problems: outcome != .ok
        case .never: false
        }
    }
}
