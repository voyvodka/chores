import Foundation
import Testing

/// The app's string catalog is kept by `scripts/sync-strings.sh` rather than Xcode, so nothing else
/// notices a key without a Turkish translation or a translation that drops a placeholder.
@Suite struct StringCatalogTests {
    struct Entry {
        let key: String
        let turkish: String?
        let state: String?
    }

    static func entries() throws -> [Entry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/ChoresApp/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = json?["strings"] as? [String: [String: Any]] ?? [:]
        return strings.compactMap { key, value in
            if value["shouldTranslate"] as? Bool == false { return nil }
            let unit = ((value["localizations"] as? [String: Any])?["tr"] as? [String: Any])?["stringUnit"]
                as? [String: Any]
            return Entry(key: key, turkish: unit?["value"] as? String,
                         state: value["extractionState"] as? String)
        }
    }

    /// Placeholders with their positions dropped, sorted: "%2$@ … %1$lld" and "%lld … %@" match.
    static func placeholders(_ text: String) -> [String] {
        let regex = /%(?:\d+\$)?(@|lld|ld|d|f|\.\d+f)/
        return text.matches(of: regex).map { String($0.output.1) }.sorted()
    }

    @Test func everyKeyHasATurkishTranslation() throws {
        let missing = try Self.entries().filter { ($0.turkish ?? "").isEmpty }.map(\.key)
        #expect(missing.isEmpty, "untranslated: \(missing.sorted())")
    }

    @Test func noStaleKeys() throws {
        let stale = try Self.entries().filter { $0.state == "stale" }.map(\.key)
        #expect(stale.isEmpty, "no longer in the code, remove from the catalog: \(stale.sorted())")
    }

    @Test func translationsKeepTheirPlaceholders() throws {
        for entry in try Self.entries() {
            guard let turkish = entry.turkish else { continue }
            #expect(Self.placeholders(entry.key) == Self.placeholders(turkish), "\(entry.key) → \(turkish)")
        }
    }
}
