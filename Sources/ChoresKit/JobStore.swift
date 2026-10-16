import Foundation

public enum ChoresJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }

    /// Accepts ISO 8601 dates with or without fractional seconds, since `job.json` is hand-written.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = try? Date(string, strategy: .iso8601) { return date }
            if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date: \(string)")
        }
        return decoder
    }
}

public enum ChoresError: Error, CustomStringConvertible, Equatable {
    case jobNotFound(String)
    case invalidDefinition(String, [String])
    case alreadyRunning(String)
    /// The runner gave up before the job started; the message is what it reported.
    case startFailed(String, String)

    public var description: String {
        switch self {
        case .jobNotFound(let id): "No job \"\(id)\" (missing job.json)"
        case .invalidDefinition(let id, let errors): "job.json of \"\(id)\" is invalid: " + errors.joined(separator: "; ")
        case .alreadyRunning(let id): "\"\(id)\" is already running; a job never runs twice at once"
        case .startFailed(let id, let message): "\"\(id)\" did not start: \(message)"
        }
    }
}

/// Reads and writes job folders. Every method tolerates a partially written or hand-edited folder.
public struct JobStore: Sendable {
    public let paths: ChoresPaths

    public init(paths: ChoresPaths) {
        self.paths = paths
    }

    public func jobIDs() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: paths.jobsDirectory.path) else { return [] }
        return entries
            .filter { fm.fileExists(atPath: paths.definitionURL($0).path) }
            .sorted()
    }

    public func definition(_ id: String) throws -> JobDefinition {
        let url = paths.definitionURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ChoresError.jobNotFound(id) }
        return try ChoresJSON.decoder.decode(JobDefinition.self, from: Data(contentsOf: url))
    }

    /// What keeps a definition from being run: its own validation errors, and an id that differs
    /// from the folder it lives in.
    public static func definitionErrors(_ job: JobDefinition, folder id: String) -> [String] {
        var errors = job.validationErrors()
        if job.id != id { errors.append("id \"\(job.id)\" does not match folder name \"\(id)\"") }
        return errors
    }

    /// The definition the runner and the scheduler accept.
    public func validDefinition(_ id: String) throws -> JobDefinition {
        let job = try definition(id)
        let errors = Self.definitionErrors(job, folder: id)
        guard errors.isEmpty else { throw ChoresError.invalidDefinition(id, errors) }
        return job
    }

    /// Why the scheduler leaves a job with a valid definition alone, or `nil` when it schedules it.
    public func schedulingBlocker(_ id: String) -> String? {
        let plist = paths.plistURL(for: id)
        guard FileManager.default.fileExists(atPath: plist.path) else { return nil }
        return "The old launch agent (\(paths.label(for: id))) is still installed; the scheduler does not start "
            + "this job until it is removed. `chores install \(id)` removes it and hands the job to the scheduler."
    }

    /// The job as the scheduler runs it, or `nil` when the scheduler skips it. The app's snapshot
    /// asks the same two questions, so what it shows cannot drift from what the scheduler does.
    public func schedulableDefinition(_ id: String) -> JobDefinition? {
        guard schedulingBlocker(id) == nil else { return nil }
        return try? validDefinition(id)
    }

    public func save(_ definition: JobDefinition) throws {
        let dir = paths.jobDirectory(definition.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = ChoresJSON.encoder
        encoder.outputFormatting.insert(.prettyPrinted)
        try encoder.encode(definition).write(to: paths.definitionURL(definition.id), options: .atomic)
    }

    /// Runs oldest first. Each line is decoded on its own and lossily, so one corrupt byte or one
    /// line from a newer schema costs that line, not the whole history.
    public func runs(_ id: String) -> [RunRecord] {
        guard let data = try? Data(contentsOf: paths.runsURL(id)) else { return [] }
        let decoder = ChoresJSON.decoder
        return Self.lines(data).compactMap { try? decoder.decode(RunRecord.self, from: $0) }
    }

    public func lastRun(_ id: String) -> RunRecord? { runs(id).last }

    static func lines(_ data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    /// Appends one line under the job's history lock. If a previous write was cut short (disk
    /// full), a newline is added first so the broken line cannot swallow this one.
    public func append(_ record: RunRecord, to id: String) throws {
        var line = try ChoresJSON.encoder.encode(record)
        line.append(0x0A)
        try withHistoryLock(id) {
            let fd = open(paths.runsURL(id).path, O_RDWR | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(fd) }
            var last: UInt8 = 0x0A
            if lseek(fd, -1, SEEK_END) >= 0, read(fd, &last, 1) == 1, last != 0x0A {
                line.insert(0x0A, at: 0)
            }
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard written == line.count else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    /// Keeps the newest `keep` lines once history exceeds `keep + slack`, deleting the logs of the
    /// runs it drops. Runs under the history lock and re-reads inside it, so a run appended by a
    /// concurrent runner is never lost; lines it cannot decode are kept verbatim.
    public func prune(_ id: String, keep: Int = 500, slack: Int = 100) {
        try? withHistoryLock(id) {
            guard let data = try? Data(contentsOf: paths.runsURL(id)) else { return }
            let all = Self.lines(data)
            guard all.count > keep + slack else { return }
            let kept = all.suffix(keep)
            let decoder = ChoresJSON.decoder
            let keptLogs = Set(kept.compactMap { try? decoder.decode(RunRecord.self, from: $0).log })
            var output = Data()
            for line in kept {
                output.append(line)
                output.append(0x0A)
            }
            try output.write(to: paths.runsURL(id), options: .atomic)
            for line in all.dropLast(keep) {
                guard let record = try? decoder.decode(RunRecord.self, from: line),
                      !keptLogs.contains(record.log) else { continue }
                try? FileManager.default.removeItem(at: paths.jobDirectory(id).appending(path: record.log))
            }
        }
    }

    /// Removes the given runs from the history, with their logs and any report kept inside the job
    /// folder; a report elsewhere belongs to the job and is left alone. Under the history lock, like
    /// `append`, so a run finishing meanwhile is kept. A run in progress has no history line yet, so
    /// it cannot be deleted. Returns how many runs were removed.
    @discardableResult
    public func deleteRuns(_ id: String, runIDs: Set<String>) throws -> Int {
        guard !runIDs.isEmpty else { return 0 }
        return try withHistoryLock(id) {
            guard let data = try? Data(contentsOf: paths.runsURL(id)) else { return 0 }
            let decoder = ChoresJSON.decoder
            var kept = Data()
            var removed: [RunRecord] = []
            var keptRecords: [RunRecord] = []
            for line in Self.lines(data) {
                let record = try? decoder.decode(RunRecord.self, from: line)
                if let record, runIDs.contains(record.id) {
                    removed.append(record)
                    continue
                }
                if let record { keptRecords.append(record) }
                kept.append(line)
                kept.append(0x0A)
            }
            guard !removed.isEmpty else { return 0 }
            try kept.write(to: paths.runsURL(id), options: .atomic)
            let directory = paths.jobDirectory(id).standardizedFileURL.path + "/"
            let stillUsed = Set(keptRecords.flatMap { [$0.log, $0.report].compactMap(\.self) })
            for record in removed {
                if !stillUsed.contains(record.log) {
                    try? FileManager.default.removeItem(at: paths.jobDirectory(id).appending(path: record.log))
                }
                if let report = record.report, !stillUsed.contains(report),
                   URL(fileURLWithPath: report).standardizedFileURL.path.hasPrefix(directory) {
                    try? FileManager.default.removeItem(atPath: report)
                }
            }
            return removed.count
        }
    }

    private func withHistoryLock<T>(_ id: String, _ body: () throws -> T) throws -> T {
        let lockPath = paths.jobDirectory(id).appending(path: ".runs.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Any live run of the job. Markers are per run, so overlapping runs cannot clear each other.
    public func running(_ id: String) -> RunningMarker? {
        let dir = paths.runningDirectory(id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let decoder = ChoresJSON.decoder
        return names.sorted().lazy
            .compactMap { try? Data(contentsOf: dir.appending(path: $0)) }
            .compactMap { try? decoder.decode(RunningMarker.self, from: $0) }
            .first { $0.isAlive }
    }

    public func setRunning(_ marker: RunningMarker, for id: String) throws {
        let dir = paths.runningDirectory(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ChoresJSON.encoder.encode(marker).write(to: dir.appending(path: "\(marker.runID).json"), options: .atomic)
    }

    public func clearRunning(_ id: String, runID: String) {
        try? FileManager.default.removeItem(at: paths.runningDirectory(id).appending(path: "\(runID).json"))
    }

    // MARK: Settings and scheduler state

    private struct Settings: Codable {
        var disabled: [String] = []
    }

    public func disabledJobs() -> Set<String> {
        guard let data = try? Data(contentsOf: paths.settingsURL),
              let settings = try? ChoresJSON.decoder.decode(Settings.self, from: data) else { return [] }
        return Set(settings.disabled)
    }

    public func setDisabled(_ id: String, _ disabled: Bool) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        var set = disabledJobs()
        if disabled { set.insert(id) } else { set.remove(id) }
        let encoder = ChoresJSON.encoder
        encoder.outputFormatting.insert(.prettyPrinted)
        try encoder.encode(Settings(disabled: set.sorted())).write(to: paths.settingsURL, options: .atomic)
    }

    public func schedulerState() -> SchedulerState {
        guard let data = try? Data(contentsOf: paths.schedulerStateURL),
              let state = try? ChoresJSON.decoder.decode(SchedulerState.self, from: data) else { return SchedulerState() }
        return state
    }

    public func saveSchedulerState(_ state: SchedulerState) throws {
        try ChoresJSON.encoder.encode(state).write(to: paths.schedulerStateURL, options: .atomic)
    }

    public func heartbeat() -> SchedulerHeartbeat? {
        guard let data = try? Data(contentsOf: paths.schedulerHeartbeatURL) else { return nil }
        return try? ChoresJSON.decoder.decode(SchedulerHeartbeat.self, from: data)
    }

    public func writeHeartbeat(_ beat: SchedulerHeartbeat) {
        try? ChoresJSON.encoder.encode(beat).write(to: paths.schedulerHeartbeatURL, options: .atomic)
    }

    /// Last `maxBytes` of a run's log, trimmed to whole lines.
    public func logTail(_ id: String, run: RunRecord, maxBytes: Int = 64 * 1024) -> String? {
        let url = paths.jobDirectory(id).appending(path: run.log)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return "" }
        // Trim on the byte, not on Character: "\r\n" is a single Character and would not match "\n".
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return String(decoding: data, as: UTF8.self)
    }
}
