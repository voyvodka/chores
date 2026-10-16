import Foundation
import Testing
@testable import ChoresKit

@Suite struct DeleteRunsTests {
    let store: JobStore
    let outside: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
        outside = root.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try store.save(JobDefinition(id: "d", title: "D", summary: "", command: ["true"], schedule: .manual))
        try FileManager.default.createDirectory(at: store.paths.jobDirectory("d").appending(path: "logs"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.paths.jobDirectory("d").appending(path: "reports"),
                                                withIntermediateDirectories: true)
    }

    /// Writes a run with its log, and a report inside the job folder or outside it.
    private func addRun(_ id: String, reportOutside: Bool = false) throws {
        let log = "logs/\(id).log"
        try Data("log \(id)".utf8).write(to: store.paths.jobDirectory("d").appending(path: log))
        let reportURL = reportOutside ? outside.appending(path: "\(id).md")
                                      : store.paths.jobDirectory("d").appending(path: "reports/\(id).md")
        try Data("report".utf8).write(to: reportURL)
        try store.append(RunRecord(id: id, startedAt: Date(), endedAt: Date(), durationSeconds: 1, exitCode: 0,
                                   outcome: .ok, report: reportURL.path, log: log, trigger: .manual), to: "d")
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: store.paths.jobDirectory("d").appending(path: relative).path)
    }

    @Test func removesSelectedRunsWithTheirFiles() throws {
        for id in ["a", "b", "c"] { try addRun(id) }
        let removed = try store.deleteRuns("d", runIDs: ["a", "c", "missing"])
        #expect(removed == 2)
        #expect(store.runs("d").map(\.id) == ["b"])
        #expect(!exists("logs/a.log") && !exists("reports/a.md") && !exists("logs/c.log"))
        #expect(exists("logs/b.log") && exists("reports/b.md"))
    }

    @Test func leavesReportsOutsideTheJobFolder() throws {
        try addRun("x", reportOutside: true)
        try store.deleteRuns("d", runIDs: ["x"])
        #expect(store.runs("d").isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.appending(path: "x.md").path))
    }

    @Test func keepsLinesItCannotDecode() throws {
        try addRun("a")
        let handle = try FileHandle(forWritingTo: store.paths.runsURL("d"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json}\n".utf8))
        try handle.close()
        try store.deleteRuns("d", runIDs: ["a"])
        let text = try String(contentsOf: store.paths.runsURL("d"), encoding: .utf8)
        #expect(text == "{not json}\n")
    }

    @Test func actionDeletesAllWhenNoIDsGiven() throws {
        for id in ["a", "b"] { try addRun(id) }
        let count = try JobActions(store: store).deleteRuns("d", runIDs: nil)
        #expect(count == 2)
        #expect(store.runs("d").isEmpty)
    }
}
