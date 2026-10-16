import Foundation
import Testing
@testable import ChoresKit

@Suite struct ScheduleTextTests {
    @Test func calendar() {
        #expect(ScheduleText.describe(Schedule(calendar: [CalendarEntry(minute: 0, hour: 10)]), language: .turkish) == "Her gün 10:00")
        #expect(ScheduleText.describe(Schedule(calendar: [CalendarEntry(minute: 30, hour: 4, weekday: 0)]), language: .turkish)
            == "Her Pazar 04:30")
        #expect(ScheduleText.describe(Schedule(calendar: [CalendarEntry(minute: 0, hour: 9, day: 1)]), language: .turkish)
            == "Her ayın 1. günü 09:00")
        #expect(ScheduleText.describe(Schedule(calendar: [CalendarEntry(minute: 15)]), language: .turkish) == "Her gün her saat :15")
    }

    @Test func intervals() {
        #expect(ScheduleText.describe(Schedule(intervalSeconds: 600), language: .turkish) == "Her 10 dakikada bir")
        #expect(ScheduleText.describe(Schedule(intervalSeconds: 21_600), language: .turkish) == "Her 6 saatte bir")
        #expect(ScheduleText.describe(Schedule(intervalSeconds: 604_800), language: .turkish) == "Haftada bir")
        #expect(ScheduleText.describe(Schedule(intervalSeconds: 3_600), language: .turkish) == "Saatte bir")
        #expect(ScheduleText.describe(Schedule(intervalSeconds: 45), language: .turkish) == "Her 45 saniyede bir")
    }

    @Test func manual() {
        #expect(ScheduleText.describe(.manual, language: .turkish) == "Yalnızca elle")
    }

    @Test func durations() {
        #expect(ScheduleText.duration(0.2, language: .turkish) == "<1 sn")
        #expect(ScheduleText.duration(42, language: .turkish) == "42 sn")
        #expect(ScheduleText.duration(125, language: .turkish) == "2 dk 5 sn")
        #expect(ScheduleText.duration(3_720, language: .turkish) == "1 sa 2 dk")
    }

    @Test func english() {
        #expect(ScheduleText.describe(Schedule(calendar: [CalendarEntry(minute: 0, hour: 10)])) == "Every day at 10:00")
        #expect(ScheduleText.describe(Schedule(calendar: [CalendarEntry(minute: 30, hour: 4, weekday: 0)]))
            == "Every Sunday at 04:30")
        #expect(ScheduleText.describe(Schedule(calendar: [CalendarEntry(minute: 0, hour: 9, day: 1, month: 3)]))
            == "On day 1 of every month at 09:00 in March")
        #expect(ScheduleText.describe(Schedule(intervalSeconds: 21_600)) == "Every 6 hours")
        #expect(ScheduleText.describe(Schedule(intervalSeconds: 3_600)) == "Every hour")
        #expect(ScheduleText.describe(.manual) == "Manual only")
        #expect(ScheduleText.duration(125) == "2 min 5 s")
    }

    @Test func turkishMonth() {
        #expect(ScheduleText.describe(CalendarEntry(minute: 0, hour: 9, month: 3), language: .turkish)
            == "Mart ayında her gün 09:00")
    }
}

@Suite struct OverviewTests {
    let store: JobStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-overview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
    }

    func record(_ outcome: Outcome, at date: Date = Date()) -> RunRecord {
        RunRecord(id: UUID().uuidString, startedAt: date, endedAt: date, durationSeconds: 1, exitCode: 0,
                  outcome: outcome, log: "logs/x.log", trigger: .launchd)
    }

    func save(_ id: String, schedule: Schedule = Schedule(intervalSeconds: 600)) throws {
        try store.save(JobDefinition(id: id, title: id.uppercased(), summary: "", command: ["true"], schedule: schedule))
    }

    @Test func loadedJobWithFailedRunNeedsAttention() throws {
        try save("a")
        try store.append(record(.fail), to: "a")
        let snap = JobOverview.snapshot(id: "a", store: store, disabled: false, now: Date())
        #expect(snap.loadState == .loaded)
        #expect(snap.attention == .fail)
        #expect(snap.nextRun?.approximate == false)
        #expect(snap.title == "A")
    }

    @Test func disabledJobIsQuietAndHasNoNextRun() throws {
        try save("b")
        try store.append(record(.fail), to: "b")
        let snap = JobOverview.snapshot(id: "b", store: store, disabled: true, now: Date())
        #expect(snap.loadState == .disabled)
        #expect(snap.attention == .ok)
        #expect(snap.nextRun == nil)
    }

    @Test func brokenDefinitionFails() throws {
        let dir = store.paths.jobDirectory("e")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.paths.definitionURL("e"))
        let snap = JobOverview.snapshot(id: "e", store: store, disabled: false, now: Date())
        #expect(snap.definition == nil)
        #expect(snap.definitionError != nil)
        #expect(snap.attention == .fail)
    }

    @Test func emptyTitleFallsBackToID() throws {
        for (id, title) in [("blank", ""), ("spaces", "  ")] {
            try store.save(JobDefinition(id: id, title: title, summary: "", command: ["true"], schedule: .manual))
            let snap = JobOverview.snapshot(id: id, store: store, disabled: false, now: Date())
            #expect(snap.definitionError != nil)
            #expect(snap.title == id)
        }
    }

    @Test func jobWithAnOldLaunchAgentIsNotShownAsScheduled() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-legacy-\(UUID().uuidString)")
        let agents = root.appending(path: "LaunchAgents")
        let store = JobStore(paths: ChoresPaths(root: root, labelPrefix: ChoresPaths.testLabelPrefix,
                                                launchAgentsDirectory: agents,
                                                runnerExecutable: URL(fileURLWithPath: "/usr/bin/true"), customRoot: true))
        try store.save(JobDefinition(id: "legacy", title: "Legacy", summary: "", command: ["true"],
                                     schedule: Schedule(intervalSeconds: 600)))
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: store.paths.plistURL(for: "legacy"))

        var seen = SchedulerState()
        seen.firstSeen["legacy"] = Date()
        let blocked = JobOverview.snapshot(id: "legacy", store: store, disabled: false, schedulerState: seen, now: Date())
        #expect(blocked.loadState == .unscheduled)
        #expect(blocked.nextRun == nil)
        #expect(blocked.schedulingError?.contains("chores install legacy") == true)
        #expect(blocked.attention == .fail)
        #expect(store.schedulableDefinition("legacy") == nil)

        try FileManager.default.removeItem(at: store.paths.plistURL(for: "legacy"))
        let handedOver = JobOverview.snapshot(id: "legacy", store: store, disabled: false, schedulerState: seen, now: Date())
        #expect(handedOver.loadState == .loaded)
        #expect(handedOver.nextRun != nil)
        #expect(handedOver.schedulingError == nil)
        #expect(store.schedulableDefinition("legacy") != nil)
    }

    @Test func jobWhoseIDDiffersFromItsFolderIsNotShownAsScheduled() throws {
        try save("folder")
        var job = try store.definition("folder")
        job.id = "other"
        try ChoresJSON.encoder.encode(job).write(to: store.paths.definitionURL("folder"))
        let snap = JobOverview.snapshot(id: "folder", store: store, disabled: false, now: Date())
        #expect(snap.definitionError?.contains("does not match folder name") == true)
        #expect(snap.loadState == .unscheduled)
        #expect(snap.nextRun == nil)
        #expect(store.schedulableDefinition("folder") == nil)
        #expect(throws: ChoresError.self) { try store.validDefinition("folder") }
    }

    @Test func aggregateIsWorstJob() throws {
        try save("f")
        try save("g")
        try store.append(record(.ok), to: "f")
        try store.append(record(.warn), to: "g")
        let snaps = ["f", "g"].map {
            JobOverview.snapshot(id: $0, store: store, disabled: false, now: Date())
        }
        #expect(JobOverview.attention(of: snaps) == .warn)
        #expect(JobOverview.attention(of: []) == .ok)
    }
}

@Suite struct RunNotifierTests {
    func snapshot(_ id: String, run: RunRecord?, notify: NotifyPolicy = .problems) -> JobSnapshot {
        let definition = JobDefinition(id: id, title: id, summary: "", command: ["true"], schedule: .manual, notify: notify)
        return JobSnapshot(id: id, label: id, definition: definition, definitionError: nil, runs: run.map { [$0] } ?? [],
                           running: nil, loadState: .loaded, nextRun: nil)
    }

    func run(_ id: String, _ outcome: Outcome, ended: Date) -> RunRecord {
        RunRecord(id: id, startedAt: ended, endedAt: ended, durationSeconds: 0, exitCode: 0, outcome: outcome,
                  log: "", trigger: .launchd)
    }

    let launch = Date(timeIntervalSince1970: 1_000)
    var later: Date { launch.addingTimeInterval(60) }

    @Test func firstLoadNeverNotifies() {
        let jobs = [snapshot("a", run: run("r1", .fail, ended: later))]
        #expect(RunNotifier.runsToNotify(previous: nil, current: jobs, since: launch).isEmpty)
    }

    @Test func newFailedRunNotifies() {
        let jobs = [snapshot("a", run: run("r2", .fail, ended: later))]
        let result = RunNotifier.runsToNotify(previous: ["a": "r1"], current: jobs, since: launch)
        #expect(result.map(\.run.id) == ["r2"])
    }

    @Test func sameRunDoesNotRepeat() {
        let jobs = [snapshot("a", run: run("r2", .fail, ended: later))]
        #expect(RunNotifier.runsToNotify(previous: ["a": "r2"], current: jobs, since: launch).isEmpty)
    }

    @Test func policyFiltersOkRuns() {
        let quiet = [snapshot("a", run: run("r2", .ok, ended: later))]
        #expect(RunNotifier.runsToNotify(previous: ["a": "r1"], current: quiet, since: launch).isEmpty)
        let chatty = [snapshot("a", run: run("r2", .ok, ended: later), notify: .always)]
        #expect(RunNotifier.runsToNotify(previous: ["a": "r1"], current: chatty, since: launch).count == 1)
    }

    func problem(_ id: String, minute: Double, _ summary: String = "CI still failing",
                 _ outcome: Outcome = .warn) -> RunRecord {
        var record = run(id, outcome, ended: launch.addingTimeInterval(minute * 60))
        record.summary = summary
        return record
    }

    @Test func repeatedProblemIsNotifiedAboutHourly() {
        let runs = stride(from: 0.0, through: 140, by: 20).enumerated().map { problem("r\($0.offset)", minute: $0.element) }
        let notified = runs.indices.filter { !RunNotifier.isRepeat(runs[$0], earlier: runs[..<$0]) }.map { runs[$0].id }
        // Minutes 0, 60 and 120.
        #expect(notified == ["r0", "r3", "r6"])
    }

    @Test func changedOrReturningProblemNotifiesAgain() {
        let first = problem("a", minute: 0)
        #expect(RunNotifier.isRepeat(problem("b", minute: 20), earlier: [first]))
        #expect(!RunNotifier.isRepeat(problem("b", minute: 20, "Another PR conflicts"), earlier: [first]))
        #expect(!RunNotifier.isRepeat(problem("b", minute: 20, "CI still failing", .fail), earlier: [first]))
        let fixed = problem("b", minute: 20, "Sorun yok", .ok)
        #expect(!RunNotifier.isRepeat(problem("c", minute: 40), earlier: [first, fixed]))
    }

    @Test func repeatIsSilentInTheApp() {
        let history = [problem("r1", minute: 0), problem("r2", minute: 20)]
        let job = JobSnapshot(id: "a", label: "a", definition: snapshot("a", run: nil).definition, definitionError: nil,
                              runs: history, running: nil, loadState: .loaded, nextRun: nil)
        #expect(RunNotifier.runsToNotify(previous: ["a": "r1"], current: [job], since: launch).isEmpty)
    }

    func job(_ id: String, runs: [RunRecord], notify: NotifyPolicy = .problems) -> JobSnapshot {
        JobSnapshot(id: id, label: id, definition: snapshot(id, run: nil, notify: notify).definition, definitionError: nil,
                    runs: runs, running: nil, loadState: .loaded, nextRun: nil)
    }

    @Test func failureFollowedBySuccessBetweenRefreshesIsNotified() {
        let runs = [run("r1", .ok, ended: later), run("r2", .fail, ended: later.addingTimeInterval(10)),
                    run("r3", .ok, ended: later.addingTimeInterval(20))]
        #expect(RunNotifier.runsToNotify(previous: ["a": "r1"], current: [job("a", runs: runs)], since: launch)
            .map(\.run.id) == ["r2"])
        #expect(RunNotifier.runsToNotify(previous: ["a": "r1"], current: [job("a", runs: runs, notify: .always)],
                                         since: launch).map(\.run.id) == ["r2", "r3"])
        #expect(RunNotifier.runsToNotify(previous: ["a": "r2"], current: [job("a", runs: runs, notify: .always)],
                                         since: launch).map(\.run.id) == ["r3"])
        #expect(RunNotifier.runsToNotify(previous: ["a": ""], current: [job("a", runs: runs)], since: launch)
            .map(\.run.id) == ["r2"])
    }

    @Test func repeatsBetweenRefreshesStaySilent() {
        let runs = [problem("r1", minute: 0), problem("r2", minute: 20), problem("r3", minute: 40)]
        #expect(RunNotifier.runsToNotify(previous: ["a": "r1"], current: [job("a", runs: runs)], since: launch).isEmpty)
    }

    @Test func seenRunMissingFromHistoryOnlyConsidersTheLastRun() {
        let runs = [run("r8", .ok, ended: later), run("r9", .fail, ended: later.addingTimeInterval(10))]
        #expect(RunNotifier.runsToNotify(previous: ["a": "pruned"], current: [job("a", runs: runs, notify: .always)],
                                         since: launch).map(\.run.id) == ["r9"])
    }

    @Test func newlyAppearedJobWithOldRunIsSilent() {
        let jobs = [snapshot("b", run: run("old", .fail, ended: launch.addingTimeInterval(-3_600)))]
        #expect(RunNotifier.runsToNotify(previous: [:], current: jobs, since: launch).isEmpty)
    }
}

@Suite struct JobStatsTests {
    func run(_ outcome: Outcome, _ duration: Double) -> RunRecord {
        RunRecord(id: UUID().uuidString, startedAt: Date(), endedAt: Date(), durationSeconds: duration, exitCode: 0,
                  outcome: outcome, log: "", trigger: .launchd)
    }

    @Test func ratesOverRecentWindow() {
        let runs = [run(.fail, 10)] + Array(repeating: run(.ok, 2), count: 3) + [run(.warn, 4)]
        let stats = JobStats(runs: runs, window: 4)
        #expect(stats.runCount == 5)
        #expect(stats.successRate == 0.75)
        #expect(stats.averageDuration == 2.5)
        #expect(stats.failures == 0)
    }

    @Test func emptyHistory() {
        let stats = JobStats(runs: [])
        #expect(stats.successRate == nil)
        #expect(stats.averageDuration == nil)
    }

    @Test func stripPadsOldestSide() {
        let strip = JobStats.strip([run(.ok, 1), run(.fail, 1)], count: 4)
        #expect(strip == [nil, nil, .ok, .fail])
        #expect(JobStats.strip(Array(repeating: run(.ok, 1), count: 12), count: 10).count == 10)
    }
}
