import ChoresKit
import Foundation
import Observation
import UserNotifications

/// Keeps the installed app on the newest release tag of the repository it was built from.
///
/// Once a day it fetches tags into its own clone (`<root>/source`, never the developer's checkout).
/// A newer `vX.Y.Z` is checked out and `scripts/update.sh` is started as a separate process: it
/// builds, waits for running jobs, runs `install.sh` (which quits this app) and reopens the app,
/// leaving the outcome in `update-state.json` for the next launch to report.
@Observable
@MainActor
final class Updater {
    static let shared = Updater(paths: JobsModel.shared.paths)

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date
    var automatic: Bool = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: Keys.automatic) }
    }

    let paths: ChoresPaths
    var sourceDirectory: URL { paths.root.appending(path: "source") }
    var stateURL: URL { paths.root.appending(path: "update-state.json") }
    var logURL: URL { paths.root.appending(path: "update.log") }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var model: JobsModel?

    private enum Keys {
        static let lastCheck = "updateLastCheck"
        static let automatic = "autoUpdate"
        /// A tag whose install failed is not retried on its own; "Install" in Settings retries it.
        static let failedTag = "updateFailedTag"
    }

    private static let checkInterval: TimeInterval = 24 * 3600

    init(paths: ChoresPaths) {
        self.paths = paths
    }

    var isAvailable: Bool { JobsModel.isInstalledBundle && AppInfo.repository != nil && !paths.customRoot }

    var installed: ReleaseVersion? { AppInfo.describe.flatMap(ReleaseVersion.init(describe:)) }

    func start(model: JobsModel) {
        guard isAvailable, timer == nil else { return }
        self.model = model
        reportFinishedUpdate()
        // Every few minutes: notices a failed build while this app still runs, and starts the daily
        // check, or a postponed install, without its own schedule.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task {
            try? await Task.sleep(for: .seconds(60))
            tick()
        }
    }

    private func tick() {
        if case .installing = state {
            reportFinishedUpdate()
            return
        }
        guard automatic else { return }
        if case let .available(tag) = state {
            install(tag, automatically: true)
        } else if lastCheck.map({ Date().timeIntervalSince($0) > Self.checkInterval }) ?? true {
            Task { await check(installing: true) }
        }
    }

    func check(installing: Bool) async {
        guard isAvailable, let repository = AppInfo.repository else { return }
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        let directory = sourceDirectory
        let result = await Task.detached { () -> Result<[String], GitError> in
            do {
                try Self.prepareClone(at: directory, repository: repository)
                try Git.run(["fetch", "--quiet", "--force", "--prune", "--tags", "origin"], in: directory)
                let tags = try Git.run(["tag", "--list", "v*"], in: directory)
                return .success(tags.split(separator: "\n").map(String.init))
            } catch let error as GitError {
                return .failure(error)
            } catch {
                return .failure(GitError(message: "\(error)"))
            }
        }.value
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: Keys.lastCheck)
        switch result {
        case let .failure(error):
            state = .failed(String(localized: "Could not check for updates: \(error.message)"))
        case let .success(tags):
            guard let newer = ReleaseVersion.update(from: installed, tags: tags) else {
                state = .upToDate
                return
            }
            state = .available(newer.tag)
            if installing { install(newer.tag, automatically: true) }
        }
    }

    /// Checks out `tag` and hands over to `update.sh`. A running job postpones it to a later tick:
    /// re-registering the scheduler at the end of the install would stop that job.
    func install(_ tag: String, automatically: Bool) {
        guard isAvailable, let model else { return }
        if automatically, UserDefaults.standard.string(forKey: Keys.failedTag) == tag { return }
        if model.anyRunning {
            state = .available(tag)
            return
        }
        state = .installing(tag)
        let directory = sourceDirectory
        let logURL = logURL
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    try Git.run(["checkout", "--quiet", "--force", "--detach", "refs/tags/\(tag)"], in: directory)
                    try Self.launchUpdateScript(in: directory, tag: tag, log: logURL)
                    return nil
                } catch let error as GitError {
                    return error.message
                } catch {
                    return "\(error)"
                }
            }.value
            if let error {
                state = .failed(String(localized: "Could not start the update to \(tag): \(error)"))
                UserDefaults.standard.set(tag, forKey: Keys.failedTag)
            }
        }
    }

    private func reportFinishedUpdate() {
        guard let data = try? Data(contentsOf: stateURL),
              let outcome = try? JSONDecoder().decode(Outcome.self, from: data) else { return }
        try? FileManager.default.removeItem(at: stateURL)
        let content = UNMutableNotificationContent()
        if outcome.ok {
            UserDefaults.standard.removeObject(forKey: Keys.failedTag)
            state = .upToDate
            content.title = String(localized: "Chores updated to \(outcome.tag)")
        } else {
            UserDefaults.standard.set(outcome.tag, forKey: Keys.failedTag)
            state = .failed(String(localized: "The update to \(outcome.tag) failed: \(outcome.message)"))
            content.title = String(localized: "Chores could not update to \(outcome.tag)")
            content.body = String(localized: "\(outcome.message). Settings › Updates shows the log.")
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(outcome.tag)",
                                                                     content: content, trigger: nil))
    }

    private struct Outcome: Decodable {
        let tag: String
        let ok: Bool
        let message: String
    }

    private nonisolated static func prepareClone(at directory: URL, repository: String) throws {
        if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
            try Git.run(["remote", "set-url", "origin", repository], in: directory)
        } else {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Git.run(["clone", "--quiet", "--no-checkout", repository, directory.path], in: nil)
        }
    }

    /// Detached from this app: install.sh quits the app, and the script has to outlive it.
    private nonisolated static func launchUpdateScript(in directory: URL, tag: String, log: URL) throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [directory.appending(path: "scripts/update.sh").path, tag]
        process.currentDirectoryURL = directory
        process.environment = Git.environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }
}

struct GitError: Error {
    let message: String
}

/// `git` without a terminal: no prompts, a fixed `PATH`, and a time limit so a stalled network
/// cannot leave the updater checking forever.
enum Git {
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env.removeValue(forKey: "CHORES_HOME")
        return env
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL?, timeout: TimeInterval = 300) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = (directory.map { ["-C", $0.path] } ?? []) + arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Reading to the end returns once git exits (or the deadline stops it); reading the second
        // pipe on another thread keeps a full stderr from blocking git.
        nonisolated(unsafe) var err = Data()
        let readErrors = DispatchWorkItem { err = errors.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(execute: readErrors)
        let out = output.fileHandleForReading.readDataToEndOfFile()
        readErrors.wait()
        process.waitUntilExit()
        deadline.cancel()
        if process.terminationReason == .uncaughtSignal {
            throw GitError(message: "git \(arguments.first ?? "") timed out")
        }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: text.isEmpty ? "git \(arguments.first ?? "") failed" : text)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
