import Foundation
import Testing
@testable import ChoresKit

/// Regressions for defects found in the pre-hand-off review.
@Suite struct ReviewRegressionTests {
    let store: JobStore

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-regress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
    }

    func save(_ id: String, script: String = "true") throws {
        try store.save(JobDefinition(id: id, title: id, summary: "", command: ["/bin/sh", "-c", script], schedule: .manual))
    }

    func record(_ id: String) -> RunRecord {
        RunRecord(id: id, startedAt: Date(), endedAt: Date(), durationSeconds: 0, exitCode: 0, outcome: .ok,
                  log: "logs/\(id).log", trigger: .launchd)
    }

    @Test func invalidUTF8InResultStillCountsAsFailure() throws {
        try save("latin1", script: "printf 'fail caf\\351\\n' > \"$CHORES_RESULT\"")
        let run = try JobRunner(store: store).run(jobID: "latin1", trigger: .manual)
        #expect(run.outcome == .fail)
    }

    @Test func folderAndIDMismatchIsRejected() throws {
        try save("real")
        var job = try store.definition("real")
        job.id = "other"
        try ChoresJSON.encoder.encode(job).write(to: store.paths.definitionURL("real"))
        #expect(throws: ChoresError.self) { try JobRunner(store: store).run(jobID: "real", trigger: .manual) }
    }

    @Test func oneCorruptLineDoesNotHideHistory() throws {
        try save("h")
        try store.append(record("a"), to: "h")
        let handle = try FileHandle(forWritingTo: store.paths.runsURL("h"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7B, 0xFF, 0xFE, 0x0A]))
        try handle.close()
        try store.append(record("b"), to: "h")
        #expect(store.runs("h").map(\.id) == ["a", "b"])
    }

    @Test func appendAfterTruncatedWriteStartsANewLine() throws {
        try save("t")
        try Data("{\"half\":".utf8).write(to: store.paths.runsURL("t"))
        try store.append(record("after"), to: "t")
        #expect(store.runs("t").map(\.id) == ["after"])
    }

    @Test func pruneKeepsLinesItCannotDecode() throws {
        try save("p")
        for i in 0..<5 { try store.append(record("r\(i)"), to: "p") }
        let handle = try FileHandle(forWritingTo: store.paths.runsURL("p"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"future\":true}\n".utf8))
        try handle.close()
        store.prune("p", keep: 3, slack: 0)
        let text = try String(contentsOf: store.paths.runsURL("p"), encoding: .utf8)
        #expect(text.contains("future"))
        #expect(store.runs("p").map(\.id) == ["r3", "r4"])
    }

    @Test func overlappingRunsKeepTheirOwnMarkers() throws {
        try save("m")
        let me = ProcessInfo.processInfo.processIdentifier
        try store.setRunning(RunningMarker(runID: "one", pid: me, startedAt: Date(), trigger: .manual), for: "m")
        try store.setRunning(RunningMarker(runID: "two", pid: me, startedAt: Date(), trigger: .manual), for: "m")
        store.clearRunning("m", runID: "one")
        #expect(store.running("m")?.runID == "two")
        store.clearRunning("m", runID: "two")
        #expect(store.running("m") == nil)
    }

    @Test func markerFromAnEarlierBootIsDead() throws {
        try save("b")
        let me = ProcessInfo.processInfo.processIdentifier
        try store.setRunning(RunningMarker(runID: "old", pid: me, startedAt: Date(), trigger: .scheduled,
                                           boot: "earlier"), for: "b")
        #expect(store.running("b") == nil)
    }

    @Test func logTailTrimsCRLFOnTheByte() throws {
        try save("crlf")
        try FileManager.default.createDirectory(at: store.paths.logsDirectory("crlf"), withIntermediateDirectories: true)
        let text = String(repeating: "abcdefghi\r\n", count: 20)
        try Data(text.utf8).write(to: store.paths.jobDirectory("crlf").appending(path: "logs/x.log"))
        var run = record("x")
        run.log = "logs/x.log"
        let tail = try #require(store.logTail("crlf", run: run, maxBytes: 25))
        #expect(tail.hasPrefix("abcdefghi"))
    }
}

@Suite struct ScheduleRegressionTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }

    func date(_ s: String) -> Date { try! Date("\(s)+03:00", strategy: .iso8601) }

    @Test func wildcardMinuteInsideTheHourIsNextMinute() {
        let next = Schedule(calendar: [CalendarEntry(hour: 9)]).nextRun(after: date("2026-09-24T09:30:10"),
                                                                        lastRunEnd: nil, calendar: cal)
        #expect(next?.date == date("2026-09-24T09:31:00"))
    }

    @Test func wildcardMinuteOutsideTheHourIsTopOfHour() {
        let next = Schedule(calendar: [CalendarEntry(hour: 9)]).nextRun(after: date("2026-09-24T12:00:00"),
                                                                        lastRunEnd: nil, calendar: cal)
        #expect(next?.date == date("2026-09-25T09:00:00"))
    }

    @Test func day31SkipsShortMonths() {
        let next = Schedule(calendar: [CalendarEntry(minute: 0, hour: 9, day: 31)])
            .nextRun(after: date("2026-09-24T12:00:00"), lastRunEnd: nil, calendar: cal)
        #expect(next?.date == date("2026-10-31T09:00:00"))
    }

    @Test func dayOrWeekdayLikeCron() {
        // Day 1 or Monday: from Thursday 2026-09-24 the next Monday (28th) comes before Oct 1.
        let next = Schedule(calendar: [CalendarEntry(minute: 0, hour: 9, day: 1, weekday: 1)])
            .nextRun(after: date("2026-09-24T12:00:00"), lastRunEnd: nil, calendar: cal)
        #expect(next?.date == date("2026-09-28T09:00:00"))
    }

    @Test func impossibleDatesAreInvalid() {
        #expect(!Schedule(calendar: [CalendarEntry(day: 30, month: 2)]).validationErrors().isEmpty)
        #expect(!Schedule(calendar: [CalendarEntry(day: 31, month: 4)]).validationErrors().isEmpty)
        #expect(Schedule(calendar: [CalendarEntry(day: 29, month: 2)]).validationErrors().isEmpty)
    }

    @Test func negativeWeekdayDoesNotCrashText() {
        #expect(ScheduleText.describe(CalendarEntry(minute: 0, hour: 1, weekday: -1), language: .turkish).hasPrefix("Her Cumartesi"))
    }
}

@Suite struct LaunchctlSafetyTests {
    @Test func labelValidation() {
        #expect(Launchctl.isValidLabel("com.example.nightly-backup"))
        #expect(Launchctl.isValidLabel("local.example.update_check"))
        #expect(!Launchctl.isValidLabel(""))
        #expect(!Launchctl.isValidLabel("nodots"))
        #expect(!Launchctl.isValidLabel("a/b.c"))
        #expect(!Launchctl.isValidLabel("has space.x"))
        #expect(!Launchctl.isValidLabel(".leading"))
    }

}
