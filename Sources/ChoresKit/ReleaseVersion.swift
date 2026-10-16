import Foundation

public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `v1.2.3` or `1.2.3`; anything else (pre-releases included) is not a release.
    public init?(tag: String) {
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// The release a build was made from, out of `git describe --tags`: `v1.2.3`, `v1.2.3-4-gabc1234`
    /// (four commits past it) or either with `-dirty`. A bare commit hash has no release.
    public init?(describe: String) {
        var text = describe
        if text.hasSuffix("-dirty") { text.removeLast("-dirty".count) }
        if let match = text.firstMatch(of: /^(.+)-\d+-g[0-9a-f]+$/) { text = String(match.output.1) }
        self.init(tag: text)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public var tag: String { "v\(description)" }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// The newest release among `tags` that is newer than `installed`. A build without a release
    /// (`installed == nil`) takes any release.
    public static func update(from installed: ReleaseVersion?, tags: [String]) -> ReleaseVersion? {
        guard let newest = tags.compactMap(ReleaseVersion.init(tag:)).max() else { return nil }
        guard let installed else { return newest }
        return newest > installed ? newest : nil
    }
}
