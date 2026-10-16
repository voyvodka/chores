import AppKit
import Foundation

/// What `scripts/install.sh` wrote into the bundle's Info.plist about the build.
enum AppInfo {
    private static func value(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `1.2.0`, or `0.0.0` for a build made before the first release tag.
    static var version: String { value("CFBundleShortVersionString") ?? "0.0.0" }
    /// `git describe --tags --always --dirty` at build time: `v1.2.0`, `v1.2.0-3-gabc1234`, `abc1234`.
    static var describe: String? { value("ChoresVersion") }
    static var commit: String? { value("ChoresCommit") }
    /// The `origin` remote of the checkout the build came from; the self-updater fetches from it.
    static var repository: String? { value("ChoresSourceRepository") }

    static var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// The repository as a web page: `git@github.com:owner/repo.git` and
    /// `https://github.com/owner/repo.git` both become `https://github.com/owner/repo`.
    static var repositoryWebURL: URL? {
        guard var text = repository else { return nil }
        if text.hasSuffix(".git") { text.removeLast(4) }
        if let match = text.firstMatch(of: /^[\w.-]+@([\w.-]+):(.+)$/) {
            text = "https://\(match.output.1)/\(match.output.2)"
        }
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }
}

/// The app's own language override, kept as `AppleLanguages` in its defaults domain: the same
/// setting System Settings › General › Language & Region › Applications writes.
enum LanguageChoice: String, CaseIterable, Identifiable {
    case system, english = "en", turkish = "tr"

    var id: String { rawValue }

    private static var domain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    static var saved: LanguageChoice {
        let languages = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String]
        guard let first = languages?.first else { return .system }
        return first.hasPrefix("tr") ? .turkish : (first.hasPrefix("en") ? .english : .system)
    }

    static func save(_ choice: LanguageChoice) {
        if choice == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([choice.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Strings are loaded once per launch, so a new language needs a fresh process. The shell waits
    /// for this one to quit, since a second instance would put a second icon in the menu bar.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? process.run()
        NSApp.terminate(nil)
    }
}
