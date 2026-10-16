import Foundation

/// What a job script writes to `$CHORES_RESULT`:
///
///     ok|warn|fail <one-line summary>
///     report <path>          (optional)
public struct ResultFile: Equatable, Sendable {
    public var outcome: Outcome?
    public var summary: String?
    public var report: String?

    public init(outcome: Outcome? = nil, summary: String? = nil, report: String? = nil) {
        self.outcome = outcome
        self.summary = summary
        self.report = report
    }

    public static func parse(_ text: String) -> ResultFile {
        var result = ResultFile()
        var sawStatus = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (head, rest) = split(line)
            if head.lowercased() == "report" {
                if !rest.isEmpty { result.report = rest }
                continue
            }
            guard !sawStatus else { continue }
            sawStatus = true
            let keyword = head.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if let outcome = Outcome(rawValue: keyword) {
                result.outcome = outcome
                result.summary = rest.isEmpty ? nil : rest
            } else {
                // No recognised keyword: keep the text as a summary and let the exit code decide.
                result.summary = line
            }
        }
        return result
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return (line, "") }
        let head = String(line[..<space])
        let rest = line[space...].trimmingCharacters(in: .whitespaces)
        return (head, rest)
    }

    /// Combines the process result with what the script reported. A non-zero exit always fails;
    /// a script can only downgrade a clean exit to `warn` or `fail`, never upgrade a failure.
    public static func resolve(exitCode: Int32, signal: Bool, timedOut: Bool, timeoutSeconds: Int?,
                               result: ResultFile?) -> (Outcome, String?) {
        if timedOut {
            return (.fail, "Timed out after \(timeoutSeconds ?? 0)s")
        }
        if signal {
            return (.fail, result?.summary ?? "Killed by signal \(exitCode)")
        }
        if exitCode != 0 {
            return (.fail, result?.summary ?? "Exited with code \(exitCode)")
        }
        return (result?.outcome ?? .ok, result?.summary)
    }
}
