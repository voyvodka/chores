import Foundation
import Testing
@testable import ChoresKit

@Suite struct SchedulerTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }

    func date(_ s: String) -> Date { try! Date("\(s)+03:00", strategy: .iso8601) }

    func job(_ id: String, _ schedule: Schedule, runAtLoad: Bool? = nil) -> JobDefinition {
        JobDefinition(id: id, title: id, summary: "", command: ["true"], schedule: schedule, runAtLoad: runAtLoad)
    }

    func input(_ jobs: [JobDefinition], lastRunEnd: [String: Date] = [:], disabled: Set<String> = [],
               running: Set<String> = []) -> Scheduler.Input {
        Scheduler.Input(jobs: jobs, lastRunEnd: lastRunEnd, disabled: disabled, running: running)
    }

    let daily = Schedule(calendar: [CalendarEntry(minute: 0, hour: 10)])

    @Test func firstSightingNeverFiresRetroactively() {
        var state = SchedulerState()
        #expect(Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-24T11:00:00"),
                              boot: "b", calendar: cal).isEmpty)
    }

    @Test func forgottenJobStartsFreshWhenRecreated() {
        var state = SchedulerState()
        _ = Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-20T09:00:00"), boot: "b", calendar: cal)
        state.forget(allExcept: [])
        #expect(state == SchedulerState())
        #expect(Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-24T11:00:00"),
                              boot: "b", calendar: cal).isEmpty)
    }

    @Test func calendarFiresWhenItsTimePasses() {
        var state = SchedulerState()
        _ = Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-24T09:59:50"), boot: "b", calendar: cal)
        let due = Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-24T10:00:05"),
                                boot: "b", calendar: cal)
        #expect(due == ["a"])
        #expect(Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-24T10:00:20"),
                              boot: "b", calendar: cal).isEmpty)
    }

    @Test func missedWhileAsleepRunsOnceOnWake() {
        var state = SchedulerState()
        _ = Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-22T09:00:00"), boot: "b", calendar: cal)
        // Asleep across two 10:00s: one catch-up run, not two.
        let due = Scheduler.due(input([job("a", daily)]), state: &state, now: date("2026-09-24T08:00:00"),
                                boot: "b", calendar: cal)
        #expect(due == ["a"])
    }

    @Test func calendarTimeWhileRunningIsSkippedAndReported() {
        var state = SchedulerState()
        let a = job("a", daily)
        _ = Scheduler.plan(input([a]), state: &state, now: date("2026-09-24T09:59:50"), boot: "b", calendar: cal)
        let during = Scheduler.plan(input([a], running: ["a"]), state: &state, now: date("2026-09-24T10:00:05"),
                                    boot: "b", calendar: cal)
        #expect(during == Scheduler.Plan(due: [], skipped: ["a"]))
        #expect(Scheduler.plan(input([a], running: ["a"]), state: &state, now: date("2026-09-24T10:00:20"),
                               boot: "b", calendar: cal) == Scheduler.Plan())
        // Not queued: the run ending does not start another.
        #expect(Scheduler.plan(input([a]), state: &state, now: date("2026-09-24T10:30:00"), boot: "b",
                               calendar: cal) == Scheduler.Plan())
    }

    @Test func intervalCountsFromLastRunEnd() {
        var state = SchedulerState()
        let tick = job("t", Schedule(intervalSeconds: 600))
        let now = date("2026-09-24T12:00:00")
        #expect(Scheduler.due(input([tick], lastRunEnd: ["t": now.addingTimeInterval(-300)]), state: &state,
                              now: now, boot: "b", calendar: cal).isEmpty)
        #expect(Scheduler.due(input([tick], lastRunEnd: ["t": now.addingTimeInterval(-601)]), state: &state,
                              now: now, boot: "b", calendar: cal) == ["t"])
    }

    @Test func intervalWithoutHistoryWaitsOneIntervalFromFirstSighting() {
        var state = SchedulerState()
        let tick = job("t", Schedule(intervalSeconds: 600))
        let start = date("2026-09-24T12:00:00")
        #expect(Scheduler.due(input([tick]), state: &state, now: start, boot: "b", calendar: cal).isEmpty)
        #expect(Scheduler.due(input([tick]), state: &state, now: start.addingTimeInterval(601), boot: "b",
                              calendar: cal) == ["t"])
    }

    @Test func runAtLoadOncePerBoot() {
        var state = SchedulerState()
        let load = job("l", Schedule(intervalSeconds: 604_800), runAtLoad: true)
        let now = date("2026-09-24T12:00:00")
        #expect(Scheduler.due(input([load]), state: &state, now: now, boot: "b1", calendar: cal) == ["l"])
        #expect(Scheduler.due(input([load], running: []), state: &state, now: now.addingTimeInterval(15), boot: "b1",
                              calendar: cal).isEmpty)
        #expect(Scheduler.due(input([load]), state: &state, now: now.addingTimeInterval(30), boot: "b2",
                              calendar: cal) == ["l"])
    }

    @Test func runAtLoadMissedWhileDisabledWaitsForTheNextBoot() {
        var state = SchedulerState()
        let load = job("l", Schedule(intervalSeconds: 604_800), runAtLoad: true)
        let now = date("2026-09-24T12:00:00")
        #expect(Scheduler.due(input([load], disabled: ["l"]), state: &state, now: now, boot: "b1", calendar: cal).isEmpty)
        #expect(Scheduler.due(input([load]), state: &state, now: now.addingTimeInterval(15), boot: "b1",
                              calendar: cal).isEmpty)
        #expect(Scheduler.due(input([load]), state: &state, now: now.addingTimeInterval(30), boot: "b2",
                              calendar: cal) == ["l"])
    }

    @Test func disabledJobsSkipTheirBacklog() {
        var state = SchedulerState()
        let a = job("a", daily)
        _ = Scheduler.due(input([a], disabled: ["a"]), state: &state, now: date("2026-09-24T09:00:00"), boot: "b", calendar: cal)
        _ = Scheduler.due(input([a], disabled: ["a"]), state: &state, now: date("2026-09-24T11:00:00"), boot: "b", calendar: cal)
        // Turned back on after 10:00 passed while off: nothing fires until tomorrow.
        #expect(Scheduler.due(input([a]), state: &state, now: date("2026-09-24T11:00:15"), boot: "b",
                              calendar: cal).isEmpty)
    }

    @Test func reenabledIntervalJobWaitsOneIntervalFromBeingTurnedBackOn() throws {
        var state = SchedulerState()
        let tick = job("t", Schedule(intervalSeconds: 600))
        let lastRun = ["t": date("2026-09-24T11:00:00")]
        for minute in [0, 15, 30] {
            let now = date("2026-09-24T12:00:00").addingTimeInterval(TimeInterval(minute * 60))
            #expect(Scheduler.due(input([tick], lastRunEnd: lastRun, disabled: ["t"]), state: &state, now: now,
                                  boot: "b", calendar: cal).isEmpty)
        }
        // Turned back on right after the 12:30 tick: overdue by the last run, but nothing fires at once.
        #expect(Scheduler.due(input([tick], lastRunEnd: lastRun), state: &state, now: date("2026-09-24T12:30:15"),
                              boot: "b", calendar: cal).isEmpty)
        #expect(Scheduler.due(input([tick], lastRunEnd: lastRun), state: &state, now: date("2026-09-24T12:39:45"),
                              boot: "b", calendar: cal).isEmpty)
        #expect(Scheduler.due(input([tick], lastRunEnd: lastRun), state: &state, now: date("2026-09-24T12:40:00"),
                              boot: "b", calendar: cal) == ["t"])

        // The app's next run agrees with the scheduler.
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-reenable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
        try store.save(tick)
        try store.append(RunRecord(id: "r", startedAt: lastRun["t"]!, endedAt: lastRun["t"]!, durationSeconds: 0,
                                   exitCode: 0, outcome: .ok, log: "logs/r.log", trigger: .scheduled), to: "t")
        let snap = JobOverview.snapshot(id: "t", store: store, disabled: false, schedulerState: state,
                                        now: date("2026-09-24T12:30:15"))
        #expect(snap.nextRun?.date == date("2026-09-24T12:40:00"))
    }

    @Test func stateWrittenBeforeANewFieldStillDecodes() throws {
        let old = #"{"firstSeen":{"a":"2026-09-24T09:00:00.000Z"},"lastChecked":{},"loadFiredBoot":{"a":"123"}}"#
        let state = try ChoresJSON.decoder.decode(SchedulerState.self, from: Data(old.utf8))
        #expect(state.loadFiredBoot == ["a": "123"])
        #expect(state.firstSeen["a"] != nil)
        #expect(state.lastSeenDisabled.isEmpty)
    }

    @Test func runningJobIsNotStartedAgain() {
        var state = SchedulerState()
        let tick = job("t", Schedule(intervalSeconds: 60))
        let now = date("2026-09-24T12:00:00")
        #expect(Scheduler.due(input([tick], lastRunEnd: ["t": now.addingTimeInterval(-120)], running: ["t"]),
                              state: &state, now: now, boot: "b", calendar: cal).isEmpty)
    }

    @Test func invalidJobIsIgnored() {
        var state = SchedulerState()
        let bad = JobDefinition(id: "x", title: "x", summary: "", command: [], schedule: Schedule(intervalSeconds: 1),
                                runAtLoad: true)
        #expect(Scheduler.due(input([bad]), state: &state, now: Date(), boot: "b", calendar: cal).isEmpty)
    }

    @Test func settingsRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
        #expect(store.disabledJobs().isEmpty)
        try store.setDisabled("a", true)
        try store.setDisabled("b", true)
        try store.setDisabled("a", false)
        #expect(store.disabledJobs() == ["b"])
    }
}
