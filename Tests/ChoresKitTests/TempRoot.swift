import Foundation

/// A throwaway `CHORES_HOME` for one test. Suites are structs, which have no deinit, so they hold this
/// and the directory goes away with the suite instance.
final class TempRoot: Sendable {
    let url: URL

    init(_ prefix: String) throws {
        url = FileManager.default.temporaryDirectory.appending(path: "\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
