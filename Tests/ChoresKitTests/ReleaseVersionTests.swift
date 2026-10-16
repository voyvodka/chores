import Testing
@testable import ChoresKit

@Suite struct ReleaseVersionTests {
    @Test func parsesTags() {
        #expect(ReleaseVersion(tag: "v1.2.3") == ReleaseVersion(major: 1, minor: 2, patch: 3))
        #expect(ReleaseVersion(tag: "1.2.3") == ReleaseVersion(major: 1, minor: 2, patch: 3))
        #expect(ReleaseVersion(tag: "v1.2") == nil)
        #expect(ReleaseVersion(tag: "v1.2.3-beta.1") == nil)
        #expect(ReleaseVersion(tag: "v1.x.3") == nil)
    }

    @Test func parsesGitDescribe() {
        #expect(ReleaseVersion(describe: "v1.2.3")?.tag == "v1.2.3")
        #expect(ReleaseVersion(describe: "v1.2.3-4-gabc1234")?.tag == "v1.2.3")
        #expect(ReleaseVersion(describe: "v1.2.3-4-gabc1234-dirty")?.tag == "v1.2.3")
        #expect(ReleaseVersion(describe: "abc1234") == nil)
    }

    @Test func comparesNumerically() {
        #expect(ReleaseVersion(tag: "v1.10.0")! > ReleaseVersion(tag: "v1.9.9")!)
        #expect(ReleaseVersion(tag: "v2.0.0")! > ReleaseVersion(tag: "v1.99.99")!)
    }

    @Test func picksOnlyANewerRelease() {
        let tags = ["v1.0.0", "v1.1.0", "v1.0.5", "not-a-release", "v1.2.0-rc.1"]
        #expect(ReleaseVersion.update(from: ReleaseVersion(tag: "v1.0.0"), tags: tags)?.tag == "v1.1.0")
        #expect(ReleaseVersion.update(from: ReleaseVersion(tag: "v1.1.0"), tags: tags) == nil)
        #expect(ReleaseVersion.update(from: ReleaseVersion(tag: "v2.0.0"), tags: tags) == nil)
        #expect(ReleaseVersion.update(from: nil, tags: tags)?.tag == "v1.1.0")
        #expect(ReleaseVersion.update(from: nil, tags: []) == nil)
    }
}
