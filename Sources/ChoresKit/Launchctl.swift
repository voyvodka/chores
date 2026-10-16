import Foundation

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Thin wrapper over `/bin/launchctl` in the user's GUI domain. Only `chores retire` and the
/// removal of pre-Chores per-job agents use it; scheduling never goes through launchd.
public struct Launchctl: Sendable {
    public let domain: String

    public init(domain: String = "gui/\(getuid())") {
        self.domain = domain
    }

    public struct Output: Sendable {
        public var status: Int32
        public var text: String
    }

    /// A hung `launchctl` must not freeze the caller (the app's refresh loop waits on these).
    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval = 15) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return Output(status: -1, text: "\(error)")
        }
        let box = DataBox()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }
        if reading.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return Output(status: -2, text: "launchctl \(arguments.joined(separator: " ")) timed out after \(Int(timeout))s")
        }
        process.waitUntilExit()
        return Output(status: process.terminationStatus, text: String(decoding: box.data, as: UTF8.self))
    }

    /// Reverse-DNS-looking, no path separators or whitespace. An empty label would make
    /// `gui/<uid>/` address the whole domain — `bootout` on that unloads every agent.
    public static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.count <= 255, label.contains("."),
              !label.hasPrefix("."), !label.hasSuffix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return label.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public func target(_ label: String) -> String {
        precondition(Self.isValidLabel(label), "invalid launchd label: \"\(label)\"")
        return "\(domain)/\(label)"
    }

    /// Returns whether the service was loaded; unloading an absent service is not an error.
    @discardableResult
    public func bootout(_ label: String) -> Bool { run(["bootout", target(label)]).status == 0 }
}
