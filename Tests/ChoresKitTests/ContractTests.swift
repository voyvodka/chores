import Foundation
import Testing
@testable import ChoresKit

@Suite struct ResultFileTests {
    @Test func parsesOutcomeSummaryAndReport() {
        let result = ResultFile.parse("warn Disk almost full\nreport reports/today.md\n")
        #expect(result == ResultFile(outcome: .warn, summary: "Disk almost full", report: "reports/today.md"))
    }

    @Test func acceptsColonAndUppercase() {
        #expect(ResultFile.parse("FAIL: no response").outcome == .fail)
        #expect(ResultFile.parse("FAIL: no response").summary == "no response")
    }

    @Test func unknownKeywordBecomesSummaryOnly() {
        let result = ResultFile.parse("DEĞİŞİKLİK YOK")
        #expect(result.outcome == nil)
        #expect(result.summary == "DEĞİŞİKLİK YOK")
    }

    @Test func onlyFirstStatusLineCounts() {
        #expect(ResultFile.parse("\n\nok first\nfail second").outcome == .ok)
    }

    @Test func nonZeroExitAlwaysFails() {
        let (outcome, summary) = ResultFile.resolve(exitCode: 3, signal: false, timedOut: false, timeoutSeconds: nil,
                                                    result: ResultFile(outcome: .ok, summary: "looked fine"))
        #expect(outcome == .fail)
        #expect(summary == "looked fine")
    }

    @Test func cleanExitWithoutResultIsOk() {
        let (outcome, summary) = ResultFile.resolve(exitCode: 0, signal: false, timedOut: false, timeoutSeconds: nil,
                                                    result: nil)
        #expect(outcome == .ok)
        #expect(summary == nil)
    }

    @Test func scriptCanDowngradeCleanExit() {
        let (outcome, _) = ResultFile.resolve(exitCode: 0, signal: false, timedOut: false, timeoutSeconds: nil,
                                              result: ResultFile(outcome: .warn))
        #expect(outcome == .warn)
    }

    @Test func timeoutWins() {
        let (outcome, summary) = ResultFile.resolve(exitCode: 15, signal: true, timedOut: true, timeoutSeconds: 30,
                                                    result: nil)
        #expect(outcome == .fail)
        #expect(summary == "Timed out after 30s")
    }
}

@Suite struct ScheduleTests {
    var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return cal
    }

    func date(_ string: String) -> Date {
        try! Date("\(string)+03:00", strategy: .iso8601)
    }

    @Test func dailyCalendarLaterToday() {
        let schedule = Schedule(calendar: [CalendarEntry(minute: 0, hour: 10)])
        let next = schedule.nextRun(after: date("2026-09-24T09:15:00"), lastRunEnd: nil, calendar: calendar)
        #expect(next == NextRun(date: date("2026-09-24T10:00:00"), approximate: false))
    }

    @Test func dailyCalendarTomorrow() {
        let schedule = Schedule(calendar: [CalendarEntry(minute: 0, hour: 10)])
        let next = schedule.nextRun(after: date("2026-09-24T10:00:00"), lastRunEnd: nil, calendar: calendar)
        #expect(next?.date == date("2026-09-25T10:00:00"))
    }

    @Test func launchdSundayIsZeroOrSeven() {
        // 2026-09-24 is a Thursday; the next Sunday is the 27th.
        for weekday in [0, 7] {
            let schedule = Schedule(calendar: [CalendarEntry(minute: 30, hour: 4, weekday: weekday)])
            let next = schedule.nextRun(after: date("2026-09-24T12:00:00"), lastRunEnd: nil, calendar: calendar)
            #expect(next?.date == date("2026-09-27T04:30:00"))
        }
    }

    @Test func earliestOfSeveralEntries() {
        let schedule = Schedule(calendar: [CalendarEntry(minute: 0, hour: 18), CalendarEntry(minute: 0, hour: 12)])
        let next = schedule.nextRun(after: date("2026-09-24T09:00:00"), lastRunEnd: nil, calendar: calendar)
        #expect(next?.date == date("2026-09-24T12:00:00"))
    }

    @Test func intervalCountsFromLastEnd() {
        let schedule = Schedule(intervalSeconds: 600)
        let next = schedule.nextRun(after: date("2026-09-24T09:05:00"), lastRunEnd: date("2026-09-24T09:00:00"),
                                    calendar: calendar)
        #expect(next == NextRun(date: date("2026-09-24T09:10:00"), approximate: false))
    }

    @Test func intervalWithoutHistoryIsUnknown() {
        #expect(Schedule(intervalSeconds: 600).nextRun(after: Date(), lastRunEnd: nil) == nil)
    }

    @Test func overdueIntervalClampsToNow() {
        let now = date("2026-09-24T12:00:00")
        let next = Schedule(intervalSeconds: 60).nextRun(after: now, lastRunEnd: date("2026-09-24T09:00:00"))
        #expect(next?.date == now)
    }

    @Test func rejectsOutOfRangeFields() {
        #expect(!Schedule(calendar: [CalendarEntry(hour: 24)]).validationErrors().isEmpty)
        #expect(!Schedule(intervalSeconds: 0).validationErrors().isEmpty)
    }
}

@Suite struct JobDefinitionTests {
    static let sample = """
    {
      "id": "api-docs-watch",
      "title": "API docs watch",
      "summary": "Checks an API's docs for changes once a day.",
      "command": ["/bin/bash", "run.sh"],
      "schedule": { "calendar": [ { "hour": 10, "minute": 0 } ] },
      "timeoutSeconds": 1500,
      "reportDirectory": "reports",
      "notify": "always",
      "permissions": "Read, Grep, Glob, WebFetch, Bash(gh api:*)",
      "notes": ["Manual run: chores run api-docs-watch"],
      "createdBy": "claude-code",
      "createdAt": "2026-09-23T22:11:00Z"
    }
    """

    @Test func decodesHandWrittenJSON() throws {
        let job = try ChoresJSON.decoder.decode(JobDefinition.self, from: Data(Self.sample.utf8))
        #expect(job.id == "api-docs-watch")
        #expect(job.schedule.calendar == [CalendarEntry(minute: 0, hour: 10)])
        #expect(job.notifyPolicy == .always)
        #expect(job.validationErrors().isEmpty)
    }

    @Test func acceptsFractionalSecondDates() throws {
        let json = Self.sample.replacingOccurrences(of: "22:11:00Z", with: "22:11:00.123Z")
        let job = try ChoresJSON.decoder.decode(JobDefinition.self, from: Data(json.utf8))
        #expect(job.createdAt != nil)
    }

    @Test func defaultNotifyIsProblemsOnly() {
        let job = JobDefinition(id: "a", title: "A", summary: "", command: ["true"], schedule: .manual)
        #expect(job.notifyPolicy == .problems)
        #expect(!job.notifyPolicy.shouldNotify(.ok))
        #expect(job.notifyPolicy.shouldNotify(.warn))
    }

    @Test func idRules() {
        #expect(JobDefinition.isValidID("api-docs-watch"))
        #expect(JobDefinition.isValidID("job2"))
        #expect(!JobDefinition.isValidID("-leading"))
        #expect(!JobDefinition.isValidID("Upper"))
        #expect(!JobDefinition.isValidID("has space"))
        #expect(!JobDefinition.isValidID("../escape"))
        #expect(!JobDefinition.isValidID(""))
    }
}

@Suite struct RunEnvironmentTests {
    @Test func defaultsThenJobOverrides() {
        let paths = ChoresPaths.current(environment: ["CHORES_HOME": "/tmp/test-root"])
        let job = JobDefinition(id: "x", title: "X", summary: "", command: ["true"], schedule: .manual,
                                environment: ["FOO": "bar", "PATH": "/custom"])
        let env = RunEnvironment.variables(for: job, paths: paths)
        #expect(env["FOO"] == "bar")
        #expect(env["PATH"] == "/custom")
        #expect(env["CHORES_HOME"] == "/tmp/test-root")
        #expect(RunEnvironment.path(for: job) == "/custom")
    }
}
