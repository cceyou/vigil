import Foundation
import Testing
@testable import VigilCore

@Suite struct MergerTests {
    private func json(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    private func hooks(_ data: Data) -> [String: Any] { json(data)["hooks"] as! [String: Any] }
    private func commands(_ data: Data, _ event: String) -> [String] {
        ((hooks(data)[event] as? [[String: Any]]) ?? []).flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
    }

    @Test func missingFileCreatesHooks() throws {
        let out = try ClaudeSettingsMerger.install(into: nil)
        for kind in ClaudeSettingsMerger.events {
            #expect(commands(out, kind.rawValue) == [ClaudeSettingsMerger.command(for: kind)])
        }
        #expect(ClaudeSettingsMerger.installedEvents(in: out) == Set(ClaudeSettingsMerger.events))
    }

    @Test func emptyFileIsTreatedAsMissing() throws {
        let out = try ClaudeSettingsMerger.install(into: Data())
        #expect(ClaudeSettingsMerger.installedEvents(in: out).count == ClaudeSettingsMerger.events.count)
    }

    @Test(arguments: ["{ not json", "[1,2,3]", "\"string\"", "{\"a\": 1,}", "{\"a\": [1,],\"b\":2}", "{\"a\": 1} extra", "// c\n{}", "{\"a\": 01}"])
    func invalidJSONThrowsAndInstallsNothing(_ text: String) {
        #expect(throws: ClaudeSettingsMerger.MergeError.self) {
            _ = try ClaudeSettingsMerger.install(into: Data(text.utf8))
        }
        #expect(throws: ClaudeSettingsMerger.MergeError.self) {
            _ = try ClaudeSettingsMerger.remove(from: Data(text.utf8))
        }
    }

    @Test func strictValidatorAcceptsRealisticSettings() throws {
        let ok = #"{"a":[1,-2.5e+3,true,false,null,"x\n\u00e9\"",{}],"b":{"c":[]},"d":0}"#
        try StrictJSON.validate(Data(ok.utf8))
        try StrictJSON.validate(Data("  {\n \"k\" : 1 \n}  \n".utf8))
    }

    @Test func unexpectedHooksStructureThrows() {
        #expect(throws: ClaudeSettingsMerger.MergeError.self) {
            _ = try ClaudeSettingsMerger.install(into: Data(#"{"hooks": []}"#.utf8))
        }
        #expect(throws: ClaudeSettingsMerger.MergeError.self) {
            _ = try ClaudeSettingsMerger.install(into: Data(#"{"hooks": {"Stop": "nope"}}"#.utf8))
        }
    }

    @Test func existingHooksAndKeysArePreserved() throws {
        let original = """
        {
          "theme": "dark",
          "enabledPlugins": {"x": true},
          "hooks": {
            "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "afplay done.aiff"}]}],
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hi"}]}]
          }
        }
        """
        let out = try ClaudeSettingsMerger.install(into: Data(original.utf8))
        let root = json(out)
        #expect(root["theme"] as? String == "dark")
        #expect((root["enabledPlugins"] as? [String: Bool]) == ["x": true])
        #expect(commands(out, "PreToolUse") == ["echo hi"])
        #expect(commands(out, "Stop").contains("afplay done.aiff"))
        #expect(commands(out, "Stop").contains(ClaudeSettingsMerger.command(for: .stop)))
        #expect(commands(out, "Stop").count == 2)
    }

    @Test func installIsIdempotent() throws {
        let once = try ClaudeSettingsMerger.install(into: Data(#"{"theme":"dark"}"#.utf8))
        let twice = try ClaudeSettingsMerger.install(into: once)
        #expect(json(once) as NSDictionary == json(twice) as NSDictionary)
        #expect(commands(twice, "Stop").count == 1)
    }

    @Test func staleOwnEntryIsReplacedNotDuplicated() throws {
        let stale = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/old/path/Vigil/hook.sh Stop"}]}]}}"#
        let out = try ClaudeSettingsMerger.install(into: Data(stale.utf8))
        #expect(commands(out, "Stop") == [ClaudeSettingsMerger.command(for: .stop)])
    }

    @Test func removalRestoresOriginalContent() throws {
        let original = """
        {"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"afplay done.aiff"}]}]}}
        """
        let installed = try ClaudeSettingsMerger.install(into: Data(original.utf8))
        let removed = try #require(try ClaudeSettingsMerger.remove(from: installed))
        #expect(json(removed) as NSDictionary == json(Data(original.utf8)) as NSDictionary)
    }

    @Test func removalWhenHooksKeyWasAbsentDropsIt() throws {
        let original = #"{"theme":"dark"}"#
        let installed = try ClaudeSettingsMerger.install(into: Data(original.utf8))
        let removed = try #require(try ClaudeSettingsMerger.remove(from: installed))
        #expect(json(removed) as NSDictionary == json(Data(original.utf8)) as NSDictionary)
    }

    @Test func removalWithNothingToRemoveReturnsNil() throws {
        #expect(try ClaudeSettingsMerger.remove(from: Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#.utf8)) == nil)
        #expect(try ClaudeSettingsMerger.remove(from: Data("{}".utf8)) == nil)
        #expect(try ClaudeSettingsMerger.remove(from: nil) == nil)
    }

    @Test func removalKeepsUsersOwnEntriesInTheSameGroup() throws {
        let mixed = """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"},{"type":"command","command":"\(ClaudeSettingsMerger.command(for: .stop).replacingOccurrences(of: "\"", with: "\\\""))"}]}]}}
        """
        let removed = try #require(try ClaudeSettingsMerger.remove(from: Data(mixed.utf8)))
        #expect(commands(removed, "Stop") == ["mine"])
    }

    // MARK: file-level installer

    @Test func installerBacksUpAndNeverOverwritesInvalidJSON() throws {
        let home = makeTempDir("vigil-home"); defer { try? FileManager.default.removeItem(at: home) }
        let paths = VigilPaths(home: home)
        try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = "{ definitely not json"
        try broken.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)

        #expect(throws: InstallError.self) { try HookInstaller(paths: paths).installHooks() }
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == broken)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: paths.claudeSettings.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains("vigil-backup") }) // aborted before any write
        #expect(!FileManager.default.fileExists(atPath: paths.hookScript.path))
    }

    @Test func installerCreatesMissingFileAndBacksUpExistingOne() throws {
        let home = makeTempDir("vigil-home"); defer { try? FileManager.default.removeItem(at: home) }
        let paths = VigilPaths(home: home)
        let installer = HookInstaller(paths: paths)

        try installer.installHooks() // file missing -> created, no backup needed
        #expect(installer.hooksInstalled)
        #expect(FileManager.default.isExecutableFile(atPath: paths.hookScript.path))

        try installer.installHooks() // now exists -> backup made, still one entry per event
        let dir = paths.claudeSettings.deletingLastPathComponent().path
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains("vigil-backup") }
        #expect(backups.count == 1)

        try installer.removeHooks()
        #expect(installer.installedEvents().isEmpty)
    }
}
