import Foundation
import Testing
@testable import ChoresKit

@Suite struct JobRunnerTests {
    let temp: TempRoot
    let root: URL
    let store: JobStore

    init() throws {
        temp = try TempRoot("chores-tests-")
        root = temp.url
        store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
    }

    func makeJob(_ id: String, script: String, timeout: Int? = nil, reportDirectory: String? = nil) throws {
        try store.save(JobDefinition(id: id, title: id, summary: "test", command: ["/bin/sh", "-c", script],
                                     schedule: .manual, timeoutSeconds: timeout, reportDirectory: reportDirectory))
    }

    @Test func recordsSuccessfulRunAndLog() throws {
        try makeJob("hello", script: "echo hello from $CHORES_JOB_ID; echo oops >&2")
        let record = try JobRunner(store: store).run(jobID: "hello", trigger: .manual)
        #expect(record.outcome == .ok)
        #expect(record.exitCode == 0)
        #expect(record.trigger == .manual)
        // Stored dates keep millisecond precision, so compare identity rather than exact equality.
        #expect(store.runs("hello").map(\.id) == [record.id])
        #expect(abs(try #require(store.lastRun("hello")).startedAt.timeIntervalSince(record.startedAt)) < 0.001)
        let log = try #require(store.logTail("hello", run: record))
        #expect(log.contains("hello from hello"))
        #expect(log.contains("oops"))
        #expect(store.running("hello") == nil)
    }

    @Test func resultFileSetsOutcomeAndSummary() throws {
        try makeJob("warns", script: "echo 'warn 2 of 3 checks passed' > \"$CHORES_RESULT\"")
        let record = try JobRunner(store: store).run(jobID: "warns", trigger: .launchd)
        #expect(record.outcome == .warn)
        #expect(record.summary == "2 of 3 checks passed")
    }

    @Test func nonZeroExitFails() throws {
        try makeJob("broken", script: "exit 3")
        let record = try JobRunner(store: store).run(jobID: "broken", trigger: .manual)
        #expect(record.outcome == .fail)
        #expect(record.exitCode == 3)
        #expect(record.summary == "Exited with code 3")
    }

    @Test func exitStatusFollowsTheRecordedOutcome() throws {
        try makeJob("reported", script: "echo 'fail upstream down' > \"$CHORES_RESULT\"; exit 0")
        let record = try JobRunner(store: store).run(jobID: "reported", trigger: .manual)
        #expect(record.exitCode == 0)
        #expect(record.outcome.exitStatus == 1)
        #expect(Outcome.ok.exitStatus == 0)
        #expect(Outcome.warn.exitStatus == 3)
    }

    @Test func timeoutKillsTheJob() throws {
        try makeJob("slow", script: "sleep 60", timeout: 1)
        let started = Date()
        let record = try JobRunner(store: store).run(jobID: "slow", trigger: .manual)
        #expect(record.timedOut == true)
        #expect(record.outcome == .fail)
        // Well under the script's 60 s; a loaded CI runner has stalled these runs by 10–15 s.
        #expect(Date().timeIntervalSince(started) < 40)
    }

    @Test func timeoutKillsAJobThatIgnoresSIGTERM() throws {
        try makeJob("stubborn", script: "trap '' TERM; sleep 60", timeout: 1)
        let started = Date()
        let record = try JobRunner(store: store).run(jobID: "stubborn", trigger: .manual)
        #expect(record.timedOut == true)
        #expect(Date().timeIntervalSince(started) < 40)
    }

    func isGone(_ pid: pid_t) -> Bool {
        // The orphan is reparented to launchd, which reaps it shortly after it dies.
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return true }
            usleep(100_000)
        }
        return false
    }

    @Test func backgroundProcessesDoNotOutliveTheRun() throws {
        try makeJob("forks", script: "sleep 30 & echo $! > child.pid")
        let record = try JobRunner(store: store).run(jobID: "forks", trigger: .manual)
        #expect(record.outcome == .ok)
        let pid = try #require(pid_t(String(decoding: Data(contentsOf: store.paths.jobDirectory("forks")
            .appending(path: "child.pid")), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(isGone(pid))
        #expect(store.logTail("forks", run: record)?.contains("stopping the processes it left running") == true)
    }

    @Test func backgroundProcessIgnoringSIGTERMIsKilled() throws {
        try makeJob("stubborn-child", script: "(trap '' TERM; sleep 60) & echo $! > child.pid")
        let started = Date()
        _ = try JobRunner(store: store).run(jobID: "stubborn-child", trigger: .manual)
        #expect(Date().timeIntervalSince(started) < 40)
        let pid = try #require(pid_t(String(decoding: Data(contentsOf: store.paths.jobDirectory("stubborn-child")
            .appending(path: "child.pid")), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(isGone(pid))
    }

    @Test func secondRunOfARunningJobIsRefusedAndRecordsNothing() throws {
        // Long enough that the second attempt cannot outwait it within the lock's patience on a slow runner.
        try makeJob("single", script: "sleep 5")
        let store = store
        nonisolated(unsafe) var firstResult: Result<RunRecord, Error>?
        let firstDone = DispatchSemaphore(value: 0)
        // A thread of its own, not a task: on a CI runner with few cores the other tests' blocking runs
        // can hold every thread of the cooperative pool, and a detached task would not start in time.
        Thread {
            firstResult = Result { try JobRunner(store: store).run(jobID: "single", trigger: .scheduled) }
            firstDone.signal()
        }.start()
        let deadline = Date().addingTimeInterval(20)
        while store.running("single") == nil, Date() < deadline { usleep(20_000) }
        #expect(store.running("single") != nil)

        var started = false
        #expect(throws: ChoresError.alreadyRunning("single")) {
            try JobRunner(store: store).run(jobID: "single", trigger: .manual) { _ in started = true }
        }
        #expect(!started)
        let logs = try FileManager.default.contentsOfDirectory(atPath: store.paths.logsDirectory("single").path)
        #expect(logs.count == 1)

        firstDone.wait()
        let record = try #require(firstResult).get()
        #expect(record.outcome == .ok)
        #expect(store.runs("single").map(\.id) == [record.id])
        // The lock goes with the run.
        #expect(try JobRunner(store: store).run(jobID: "single", trigger: .manual).outcome == .ok)
    }

    @Test func onStartReportsTheRunID() throws {
        try makeJob("announces", script: "true")
        var announced: String?
        let record = try JobRunner(store: store).run(jobID: "announces", trigger: .manual) { announced = $0 }
        #expect(announced == record.id)
    }

    @Test func startSurfacesARunnerThatFailsBeforeTheJobStarts() throws {
        try makeJob("refused", script: "true")
        let job = try store.definition("refused")
        let runner = try fakeRunner("echo 'chores: \"refused\" is already running' >&2; exit 2")
        #expect(throws: ChoresError.startFailed("refused", "\"refused\" is already running")) {
            try JobActions.start(job: job, runner: runner, paths: store.paths, trigger: .manual)
        }
        let silent = try fakeRunner("kill -9 $$")
        #expect(throws: ChoresError.self) {
            try JobActions.start(job: job, runner: silent, paths: store.paths, trigger: .manual)
        }
    }

    @Test func startAcceptsARunThatFinishesBeforeItIsPolled() throws {
        try makeJob("quick", script: "true")
        let job = try store.definition("quick")
        let runner = try fakeRunner("printf r1 > \"$CHORES_STARTED_FILE\"; exit 1")
        let process = try JobActions.start(job: job, runner: runner, paths: store.paths, trigger: .manual)
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
    }

    func fakeRunner(_ body: String) throws -> URL {
        let url = root.appending(path: "runner-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func runsGetTheFixedPathWhoeverStartsThem() throws {
        try makeJob("env", script: "printf 'ok %s\\n' \"$PATH\" > \"$CHORES_RESULT\"")
        let record = try JobRunner(store: store).run(jobID: "env", trigger: .manual)
        #expect(record.summary == RunEnvironment.defaultPath)
    }

    @Test func picksUpReportWrittenDuringRun() throws {
        try makeJob("reporter", script: "echo '# report' > \"$CHORES_REPORT_DIR/today.md\"", reportDirectory: "reports")
        let record = try JobRunner(store: store).run(jobID: "reporter", trigger: .manual)
        #expect(record.report?.hasSuffix("/jobs/reporter/reports/today.md") == true)
    }

    @Test func declaredReportWins() throws {
        try makeJob("declared", script: "printf 'ok done\\nreport notes/x.md\\n' > \"$CHORES_RESULT\"")
        let record = try JobRunner(store: store).run(jobID: "declared", trigger: .manual)
        #expect(record.report?.hasSuffix("/jobs/declared/notes/x.md") == true)
    }

    @Test func historyAccumulatesAndSkipsCorruptLines() throws {
        try makeJob("twice", script: "true")
        let runner = JobRunner(store: store)
        _ = try runner.run(jobID: "twice", trigger: .manual)
        let handle = try FileHandle(forWritingTo: store.paths.runsURL("twice"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        _ = try runner.run(jobID: "twice", trigger: .manual)
        #expect(store.runs("twice").count == 2)
        #expect(store.jobIDs() == ["twice"])
    }

    @Test func invalidDefinitionIsRejected() throws {
        try makeJob("bad", script: "true")
        var job = try store.definition("bad")
        job.command = []
        try store.save(job)
        #expect(throws: ChoresError.self) { try JobRunner(store: store).run(jobID: "bad", trigger: .manual) }
    }

    @Test func runIDsSortChronologically() {
        let a = JobRunner.makeRunID(Date(timeIntervalSince1970: 1_000_000))
        let b = JobRunner.makeRunID(Date(timeIntervalSince1970: 1_000_001))
        #expect(a < b)
        #expect(a.hasPrefix("19700112T134640Z"))
    }
}

@Suite struct PruneTests {
    @Test func keepsNewestRunsAndDeletesTheirDroppedLogs() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
        try store.save(JobDefinition(id: "busy", title: "busy", summary: "", command: ["true"], schedule: .manual))
        try FileManager.default.createDirectory(at: store.paths.logsDirectory("busy"), withIntermediateDirectories: true)
        for i in 0..<15 {
            let log = "logs/run-\(i).log"
            FileManager.default.createFile(atPath: store.paths.jobDirectory("busy").appending(path: log).path, contents: nil)
            try store.append(RunRecord(id: "r\(i)", startedAt: Date(), endedAt: Date(), durationSeconds: 0, exitCode: 0,
                                       outcome: .ok, log: log, trigger: .launchd), to: "busy")
        }
        store.prune("busy", keep: 10, slack: 10)
        #expect(store.runs("busy").count == 15)

        store.prune("busy", keep: 10, slack: 2)
        #expect(store.runs("busy").map(\.id) == (5..<15).map { "r\($0)" })
        let logs = try FileManager.default.contentsOfDirectory(atPath: store.paths.logsDirectory("busy").path)
        #expect(logs.count == 10)
        #expect(!logs.contains("run-0.log"))
    }
}
