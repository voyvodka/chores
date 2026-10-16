import Foundation
import Testing
@testable import ChoresKit

/// Uses the built `chores` runner: stopping signals a runner process found by its name.
@Suite struct StopTests {
    static let runner = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: ".build/debug/chores")

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: runner.path), "needs swift build"))
    func stopRecordsARunStoppedByTheUserThatDoesNotNotify() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "chores-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
        try store.save(JobDefinition(id: "long", title: "long", summary: "", command: ["/bin/sh", "-c", "sleep 60"],
                                     schedule: .manual))
        let actions = JobActions(store: store, runner: Self.runner)
        try actions.runNow("long")
        try actions.stop("long")

        let deadline = Date().addingTimeInterval(30)
        while store.runs("long").isEmpty, Date() < deadline { usleep(100_000) }
        let run = try #require(store.runs("long").last)
        #expect(run.summary == "Stopped by the user")
        #expect(run.stoppedByUser == true)
        #expect(run.outcome == .fail)
        #expect(run.durationSeconds < 30)
        #expect(!RunNotifier.deserves(run, policy: .always, earlier: []))
        #expect(throws: ChoresError.notRunning("long")) { try actions.stop("long") }
    }

    @Test func aPidThatIsNotARunnerIsNeverSignalled() {
        #expect(!JobActions.isRunner(ProcessInfo.processInfo.processIdentifier))
        #expect(!JobActions.isRunner(999_999))
    }
}
