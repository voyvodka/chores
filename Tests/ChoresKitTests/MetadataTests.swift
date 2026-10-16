import Foundation
import Testing
@testable import ChoresKit

@Suite struct MetadataTests {
    let temp: TempRoot
    let store: JobStore

    init() throws {
        temp = try TempRoot("chores-meta-")
        let root = temp.url
        store = JobStore(paths: ChoresPaths.current(environment: ["CHORES_HOME": root.path]))
    }

    @Test func decodesMetadata() throws {
        let json = """
        {"id":"m","title":"M","summary":"s","command":["true"],"schedule":{},
         "version":"1.2.0","category":"watch","requires":["sh","gh"],"project":"~/Projects/example",
         "changelog":[{"version":"1.2.0","date":"2026-09-24","notes":["Faster"]},{"version":"1.0.0","notes":["First"]}],
         "links":[{"title":"Docs","url":"https://example.com"},{"title":"Repo","url":"~/Projects/example"}]}
        """
        let job = try ChoresJSON.decoder.decode(JobDefinition.self, from: Data(json.utf8))
        #expect(job.version == "1.2.0")
        #expect(job.changelog?.first?.notes == ["Faster"])
        #expect(job.links?.first?.resolvedURL?.absoluteString == "https://example.com")
        #expect(job.links?.last?.resolvedURL?.isFileURL == true)
        #expect(job.projectURL?.path.hasSuffix("/Projects/example") == true)
    }

    @Test func warningsForMissingVersionAndChangelog() {
        var job = JobDefinition(id: "w", title: "W", summary: "", command: ["true"], schedule: .manual)
        #expect(job.validationWarnings().contains { $0.contains("no version") })
        job.version = "2.0.0"
        job.changelog = [ChangelogEntry(version: "1.0.0", notes: ["old"])]
        job.category = "maintenance"
        #expect(job.validationWarnings() == ["changelog has no entry for version 2.0.0"])
    }

    @Test func requirementsResolvedOnGivenPath() {
        #expect(Requirements.missing(["sh", "definitely-not-a-command-xyz"], path: "/usr/bin:/bin")
            == ["definitely-not-a-command-xyz"])
        #expect(Requirements.missing(["/bin/sh"], path: "") == [])
        #expect(Requirements.missing(["/nope/tool"], path: "/bin") == ["/nope/tool"])
    }

    @Test func runRecordsJobVersion() throws {
        try store.save(JobDefinition(id: "v", title: "V", summary: "", command: ["true"], schedule: .manual,
                                     version: "3.1.0"))
        let run = try JobRunner(store: store).run(jobID: "v", trigger: .manual)
        #expect(run.jobVersion == "3.1.0")
        #expect(store.lastRun("v")?.jobVersion == "3.1.0")
    }

    @Test func missingRequirementWarns() throws {
        try store.save(JobDefinition(id: "r", title: "R", summary: "", command: ["true"], schedule: .manual,
                                     requires: ["definitely-not-a-command-xyz"]))
        let snap = JobOverview.snapshot(id: "r", store: store, disabled: false, now: Date())
        #expect(snap.missingRequirements == ["definitely-not-a-command-xyz"])
        #expect(snap.attention == .warn)
    }

    @Test func groupsByCategoryWithUncategorizedLast() {
        func snap(_ id: String, _ category: String?) -> JobSnapshot {
            JobSnapshot(id: id, label: id,
                        definition: JobDefinition(id: id, title: id, summary: "", command: ["true"], schedule: .manual,
                                                  category: category),
                        definitionError: nil, runs: [], running: nil, loadState: .loaded, nextRun: nil)
        }
        let groups = JobOverview.grouped([snap("a", nil), snap("b", "sync"), snap("c", "Watch"), snap("d", "maintenance")])
        #expect(groups.map(\.category) == ["maintenance", "sync", "watch", JobOverview.uncategorized])
    }
}
