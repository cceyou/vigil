import Foundation
import Testing
@testable import VigilCore

@Suite struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func catalog() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["strings"] as! [String: Any]
    }

    private static func keysUsedInCode() throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\bL\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                keys.insert(String(text[Range(m.range(at: 1), in: text)!]))
            }
        }
        return keys
    }

    private func czech(_ entry: Any?) -> String? {
        let loc = ((entry as? [String: Any])?["localizations"] as? [String: Any])?["cs"] as? [String: Any]
        return (loc?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    private func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%[@d]")
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }

    @Test func everyStringUsedInCodeHasACzechTranslation() throws {
        let catalog = try Self.catalog()
        let used = try Self.keysUsedInCode()
        #expect(used.count > 50) // the scan itself works
        for key in used.sorted() {
            let value = czech(catalog[key])
            #expect(value != nil && !value!.isEmpty, "missing Czech translation: \(key)")
        }
    }

    /// One tone: formal "vy", like macOS ("spusťte", "můžete pokračovat", "vaši"). Catches informal "ty" forms:
    /// second-person singular verbs (-eš, -áš, "jsi"), "ty" pronouns and possessives, and common informal imperatives.
    @Test func czechUsesTheFormalYouEverywhere() throws {
        let catalog = try Self.catalog()
        // "ty"/"ti" are left out: they are also the plural "those" ("ty hooky"). "váš" is formal.
        let words = [#"\w+eš"#, #"(?!váš\b)\w+áš"#, "jsi", "tebe", "tobě", "tě", "tvůj", "tvoje?", "tvá", "tvé", "tvých", "tvým", "tvou",
                     "spusť", "klikni", "otevři", "zkus", "zapni", "vypni", "připoj", "nainstaluj", "restartuj", "aktualizuj",
                     "počkej", "nech", "podívej", "zkontroluj", "povol"]
        let informal = try NSRegularExpression(pattern: #"(?i)\b("# + words.joined(separator: "|") + #")\b"#)
        var checked = 0
        for (key, entry) in catalog {
            guard let value = czech(entry) else { continue }
            checked += 1
            let range = NSRange(value.startIndex..., in: value)
            let hits = informal.matches(in: value, range: range).map { String(value[Range($0.range, in: value)!]) }
            #expect(hits.isEmpty, "informal Czech \(hits) in \"\(value)\" (key: \(key))")
        }
        #expect(checked > 200)
        // The pattern itself works.
        for sample in ["Data z 14:02 — spusť Claude Code", "Limit obnoven — můžeš pokračovat", "tvůj Mac"] {
            #expect(informal.firstMatch(in: sample, range: NSRange(sample.startIndex..., in: sample)) != nil, "\(sample)")
        }
    }

    @Test func translationsKeepTheSameFormatSpecifiers() throws {
        let catalog = try Self.catalog()
        for (key, entry) in catalog {
            guard let value = czech(entry) else { continue }
            #expect(specifiers(key) == specifiers(value), "format specifiers differ: \(key)")
        }
    }
}
