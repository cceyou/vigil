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

    // MARK: versioned hook set

    /// settings.json as written by the first Vigil release: six unstamped hooks, plus the user's own hooks,
    /// one of them sharing a group with ours.
    private static let v1Settings = """
    {
      "theme": "dark",
      "hooks": {
        "SessionStart": [{"hooks": [{"type": "command", "command": "\\"$HOME/Library/Application Support/Vigil/hook.sh\\" SessionStart", "timeout": 5}]}],
        "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\\"$HOME/Library/Application Support/Vigil/hook.sh\\" UserPromptSubmit", "timeout": 5}]}],
        "Stop": [
          {"matcher": "", "hooks": [{"type": "command", "command": "afplay done.aiff"},
                                    {"type": "command", "command": "\\"$HOME/Library/Application Support/Vigil/hook.sh\\" Stop", "timeout": 5}]}
        ],
        "Notification": [{"hooks": [{"type": "command", "command": "\\"$HOME/Library/Application Support/Vigil/hook.sh\\" Notification", "timeout": 5}]}],
        "SessionEnd": [{"hooks": [{"type": "command", "command": "\\"$HOME/Library/Application Support/Vigil/hook.sh\\" SessionEnd", "timeout": 5}]}],
        "PostToolUse": [{"hooks": [{"type": "command", "command": "\\"$HOME/Library/Application Support/Vigil/hook.sh\\" PostToolUse", "timeout": 5}]}],
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo hi"}]}],
        "SubagentStop": [{"hooks": [{"type": "command", "command": "notify-subagent-done"}]}]
      }
    }
    """

    @Test func commandsCarryTheVersionStamp() {
        for kind in ClaudeSettingsMerger.events {
            let cmd = ClaudeSettingsMerger.command(for: kind)
            #expect(cmd.contains(ClaudeSettingsMerger.marker))
            #expect(ClaudeSettingsMerger.version(of: cmd) == ClaudeSettingsMerger.version)
        }
        #expect(ClaudeSettingsMerger.version(of: "\"$HOME/Library/Application Support/Vigil/hook.sh\" Stop") == 1)
        #expect(ClaudeSettingsMerger.events.contains(.subagentStart))
        #expect(ClaudeSettingsMerger.events.contains(.subagentStop))
    }

    @Test func toolHooksMatchEveryToolAndVersionIsBumped() throws {
        #expect(ClaudeSettingsMerger.version >= 3)
        #expect(ClaudeSettingsMerger.events.contains(.permissionRequest))
        #expect(ClaudeSettingsMerger.events.contains(.postToolUse))
        let out = try ClaudeSettingsMerger.install(into: nil)
        for event in ["PostToolUse", "PermissionRequest"] {
            let groups = hooks(out)[event] as! [[String: Any]]
            #expect(groups.count == 1)
            #expect(groups[0]["matcher"] as? String == "*", "\(event)")
        }
        // Non-tool events carry no matcher.
        #expect((hooks(out)["Notification"] as! [[String: Any]])[0]["matcher"] == nil)
        // A v2 install (no PermissionRequest) shows up as outdated, so "Update hooks" appears.
        let v2 = String(decoding: out, as: UTF8.self)
            .replacingOccurrences(of: "--vigil-hooks=\(ClaudeSettingsMerger.version)", with: "--vigil-hooks=2")
        #expect(ClaudeSettingsMerger.status(in: Data(v2.utf8)) == .outdated)
    }

    @Test func statusDetectsMissingOutdatedAndCurrent() throws {
        #expect(ClaudeSettingsMerger.status(in: nil) == .missing)
        #expect(ClaudeSettingsMerger.status(in: Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}"#.utf8)) == .missing)
        let old = Data(Self.v1Settings.utf8)
        #expect(ClaudeSettingsMerger.status(in: old) == .outdated)
        #expect(ClaudeSettingsMerger.missingEvents(in: old) == [.permissionRequest, .subagentStart, .subagentStop])
        #expect(ClaudeSettingsMerger.status(in: try ClaudeSettingsMerger.install(into: old)) == .current)
        // All events present but one still unstamped: outdated too.
        var partial = try ClaudeSettingsMerger.install(into: nil)
        partial = Data(String(decoding: partial, as: UTF8.self)
            .replacingOccurrences(of: "Stop --vigil-hooks=\(ClaudeSettingsMerger.version)", with: "Stop").utf8)
        #expect(ClaudeSettingsMerger.status(in: partial) == .outdated)
    }

    @Test func upgradeFromV1KeepsForeignHooksAndIsIdempotent() throws {
        let old = Data(Self.v1Settings.utf8)
        let upgraded = try ClaudeSettingsMerger.install(into: old)
        let root = json(upgraded)
        #expect(root["theme"] as? String == "dark")
        // Foreign hooks untouched, including the one that shared a group with ours and a foreign SubagentStop.
        #expect(commands(upgraded, "PreToolUse") == ["echo hi"])
        #expect(commands(upgraded, "Stop").filter { !$0.contains(ClaudeSettingsMerger.marker) } == ["afplay done.aiff"])
        #expect(commands(upgraded, "SubagentStop").contains("notify-subagent-done"))
        let stopGroups = hooks(upgraded)["Stop"] as! [[String: Any]]
        #expect(stopGroups.contains { $0["matcher"] as? String == "" && (($0["hooks"] as? [[String: Any]])?.count == 1) })
        // Exactly one entry of ours per event, all at the current version; no unstamped leftovers.
        for kind in ClaudeSettingsMerger.events {
            let ours = commands(upgraded, kind.rawValue).filter { $0.contains(ClaudeSettingsMerger.marker) }
            #expect(ours == [ClaudeSettingsMerger.command(for: kind)])
        }
        // Idempotent: a second run changes nothing.
        let again = try ClaudeSettingsMerger.install(into: upgraded)
        #expect(json(again) as NSDictionary == root as NSDictionary)
        #expect(again == upgraded)
        // And removal leaves only the user's hooks.
        let removed = try #require(try ClaudeSettingsMerger.remove(from: again))
        #expect(!String(decoding: removed, as: UTF8.self).contains(ClaudeSettingsMerger.marker))
        #expect(commands(removed, "Stop") == ["afplay done.aiff"])
        #expect(commands(removed, "SubagentStop") == ["notify-subagent-done"])
        #expect(commands(removed, "PreToolUse") == ["echo hi"])
    }

    @Test func installerReportsOutdatedAndUpdateFixesIt() throws {
        let home = makeTempDir("vigil-home"); defer { try? FileManager.default.removeItem(at: home) }
        let paths = VigilPaths(home: home)
        try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.v1Settings.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
        let installer = HookInstaller(paths: paths)
        #expect(installer.hookStatus() == .outdated)
        #expect(!installer.hooksInstalled)
        try installer.installHooks()
        #expect(installer.hookStatus() == .current)
        #expect(installer.hooksInstalled)
        let dir = paths.claudeSettings.deletingLastPathComponent().path
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).contains { $0.contains("vigil-backup") })
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
