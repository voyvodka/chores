import ChoresKit
import CoreServices
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// App-wide state: the job snapshots, refreshed when job folders change and on a timer.
@Observable
@MainActor
final class JobsModel {
    static let shared = JobsModel()
    /// Set by `--snapshot`, so views skip side effects (activation, live refresh) while rendering.
    nonisolated(unsafe) static var isSnapshot = false

    /// True only for the installed Chores.app. A development binary must never register a login
    /// item (it shows up as a second "ChoresApp" entry) or touch notifications.
    nonisolated static var isInstalledBundle: Bool {
        Bundle.main.bundleIdentifier == ChoresPaths.appBundleIdentifier && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private(set) var jobs: [JobSnapshot] = []
    private(set) var lastRefresh: Date?
    var selectedJobID: String?
    /// Set to ask the always-present menu-bar label to open the window (e.g. from a notification).
    private(set) var windowRequest: WindowRequest?
    var actionError: String?
    private(set) var busyJobIDs: Set<String> = []
    private(set) var loginItemStatus = SMAppService.mainApp.status
    /// Drives the refresh button: spins while a user-requested reload runs, then briefly confirms.
    private(set) var refreshFeedback: RefreshFeedback = .idle
    /// From the scheduler's heartbeat file; false means no job will run on schedule.
    private(set) var schedulerRunning = true
    /// Shown inside the menu, where the login toggle lives.
    var loginItemError: String?

    let paths: ChoresPaths
    let store: JobStore
    /// The runner inside the installed bundle, the same one the scheduler uses.
    let runner: URL

    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh = false
    /// Last run id per job at the previous refresh; `nil` until the first load, so runs that
    /// happened before launch never notify.
    @ObservationIgnored private var knownLastRuns: [String: String]?
    @ObservationIgnored private let startedAt = Date()
    @ObservationIgnored private var didAutoSelect = false

    init(paths: ChoresPaths = .current()) {
        self.paths = paths
        self.store = JobStore(paths: paths)
        self.runner = Bundle.main.url(forAuxiliaryExecutable: "chores") ?? paths.runnerExecutable
    }

    static let schedulerAgent = SMAppService.agent(plistName: "\(ChoresPaths.schedulerLabel).plist")

    var launchAtLogin: Bool { loginItemStatus == .enabled }
    var attention: Outcome { JobOverview.attention(of: jobs) }
    var anyRunning: Bool { jobs.contains(where: \.isRunning) }

    var selectedJob: JobSnapshot? {
        jobs.first { $0.id == selectedJobID }
    }

    func start() {
        guard watcher == nil else { return }
        registerLoginItemOnce()
        ensureScheduler()
        Updater.shared.start(model: self)
        try? FileManager.default.createDirectory(at: paths.jobsDirectory, withIntermediateDirectories: true)
        watcher = DirectoryWatcher(url: paths.jobsDirectory) { [weak self] in self?.refresh() }
        // The scheduler heartbeat and relative times change without any file event.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Coalesces bursts of file events into at most one load in flight plus one queued.
    func refresh() {
        guard refreshTask == nil else {
            pendingRefresh = true
            return
        }
        let store = store
        refreshTask = Task { [weak self] in
            let (snapshots, beat) = await Task.detached { (JobOverview.load(store: store), store.heartbeat()) }.value
            guard let self else { return }
            self.schedulerRunning = beat?.isFresh() ?? false
            self.apply(snapshots)
            self.refreshTask = nil
            if self.pendingRefresh {
                self.pendingRefresh = false
                self.refresh()
            }
        }
    }

    /// A refresh the user asked for. Loading usually takes a few milliseconds, so the spinner stays
    /// for at least 0.4 s and a short "just updated" note follows; otherwise the click looks inert.
    func userRefresh() {
        guard refreshFeedback == .idle else { return }
        refreshFeedback = .spinning
        let started = Date()
        refresh()
        Task { [weak self] in
            while self?.refreshTask != nil { try? await Task.sleep(for: .milliseconds(50)) }
            let remaining = 0.4 - Date().timeIntervalSince(started)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            self?.refreshFeedback = .done
            try? await Task.sleep(for: .seconds(2))
            if self?.refreshFeedback == .done { self?.refreshFeedback = .idle }
        }
    }

    func replaceForSnapshot(_ snapshots: [JobSnapshot], refreshFeedback: RefreshFeedback = .idle) {
        jobs = snapshots
        self.refreshFeedback = refreshFeedback
    }

    private func apply(_ snapshots: [JobSnapshot]) {
        notifyNewRuns(in: snapshots)
        if snapshots != jobs { jobs = snapshots }
        lastRefresh = Date()
        // Select the first job once, and again only when the selected one disappears; a deliberate
        // deselect in the sidebar stays deselected.
        let selectionGone = selectedJobID.map { id in !snapshots.contains { $0.id == id } } ?? false
        if selectionGone || (!didAutoSelect && selectedJobID == nil) {
            selectedJobID = snapshots.first?.id
        }
        if !snapshots.isEmpty { didAutoSelect = true }
    }
}

// MARK: - Actions

extension JobsModel {
    func runNow(_ id: String) { perform(id) { try $0.runNow(id) } }
    func stop(_ id: String) { perform(id) { try $0.stop(id) } }
    func setEnabled(_ id: String, _ enabled: Bool) {
        perform(id) { enabled ? try $0.turnOn(id) : try $0.turnOff(id) }
    }

    /// Runs a job action off the main thread, then refreshes.
    private func perform(_ id: String, _ action: @escaping @Sendable (JobActions) throws -> Void) {
        let actions = JobActions(store: store, runner: runner)
        busyJobIDs.insert(id)
        Task {
            let error = await Task.detached { () -> String? in
                do {
                    try action(actions)
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value
            busyJobIDs.remove(id)
            if let error { actionError = error }
            refresh()
        }
    }

    func deleteRuns(_ id: String, _ runIDs: Set<String>?) {
        perform(id) { try $0.deleteRuns(id, runIDs: runIDs) }
    }

    func requestWindow(for jobID: String?) {
        if let jobID { selectedJobID = jobID }
        windowRequest = WindowRequest()
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = String(localized: "Could not change open at login: \(error.localizedDescription)")
        }
        refreshLoginItemStatus()
        return loginItemError == nil
    }

    /// Re-read on every menu opening: the user can change it in System Settings › Login Items.
    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
    }

    /// Registers the scheduler agent embedded in the bundle if it is not already; with it off, no
    /// job runs on schedule.
    func ensureScheduler() {
        guard Self.isInstalledBundle, Self.schedulerAgent.status != .enabled else { return }
        do {
            try Self.schedulerAgent.register()
        } catch {
            actionError = String(localized: "Could not start the scheduler: \(error.localizedDescription)")
        }
        refresh()
    }

    /// The banner's button. A registered agent can still be dead (launchd refuses an agent whose
    /// bundle signature changed), so it is registered afresh rather than only when missing.
    func restartScheduler() {
        guard Self.isInstalledBundle else {
            actionError = String(localized: "Only the installed Chores.app in ~/Applications can start the scheduler.")
            return
        }
        do {
            if Self.schedulerAgent.status == .enabled { try Self.schedulerAgent.unregister() }
            try Self.schedulerAgent.register()
        } catch {
            actionError = String(localized: "Could not start the scheduler: \(error.localizedDescription)")
        }
        refresh()
    }

    /// The app is only useful while it runs, so it adds itself as a login item on first launch;
    /// the menu toggle turns it off for good.
    private func registerLoginItemOnce() {
        guard Self.isInstalledBundle else { return }
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if SMAppService.mainApp.status == .enabled || setLaunchAtLogin(true) {
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    // MARK: Notifications

    private func notifyNewRuns(in snapshots: [JobSnapshot]) {
        defer { knownLastRuns = RunNotifier.lastRunIDs(snapshots) }
        guard Self.isInstalledBundle else { return }
        for (job, run) in RunNotifier.runsToNotify(previous: knownLastRuns, current: snapshots, since: startedAt) {
            let content = UNMutableNotificationContent()
            content.title = "\(job.title) · \(run.outcome.label)"
            content.body = run.summary ?? String(localized: "Finished in \(Fmt.duration(run.durationSeconds))")
            content.userInfo = ["jobID": job.id, "runID": run.id]
            if run.outcome != .ok { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: run.id, content: content, trigger: nil))
        }
    }
}

enum RefreshFeedback: Equatable {
    case idle, spinning, done
}

struct WindowRequest: Equatable {
    let id = UUID()
}

/// FSEvents stream over a directory tree, delivering on the main queue.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor () -> Void

    init(url: URL, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            // A running job writes its log continuously; only state files change what the app shows.
            guard changed.count < count || changed.contains(where: DirectoryWatcher.isRelevant) else { return }
            MainActor.assumeIsolated { watcher.handler() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                             | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [url.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    static func isRelevant(_ path: String) -> Bool {
        !path.contains("/logs/") && !path.contains("/reports/") && !path.hasSuffix("/.manual-trigger")
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
