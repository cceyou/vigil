import Foundation
import Testing
@testable import VigilCore

@Suite(.serialized) struct StatusLineInstallerTests {
    private func json(_ data: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: data) as! [String: Any] }

    private func setUp(_ settings: String?) throws -> (URL, VigilPaths) {
        let home = makeTempDir("vigil-home")
        let paths = VigilPaths(home: home)
        if let settings {
            try FileManager.default.createDirectory(at: paths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try settings.write(to: paths.claudeSettings, atomically: true, encoding: .utf8)
        }
        return (home, paths)
    }

    private func settings(_ paths: VigilPaths) throws -> [String: Any] { json(try Data(contentsOf: paths.claudeSettings)) }
    private func statusCommand(_ paths: VigilPaths) throws -> String? {
        (try settings(paths)["statusLine"] as? [String: Any])?["command"] as? String
    }

    // MARK: merger

    @Test func noPreviousStatusLine() throws {
        let result = try #require(try StatusLineMerger.install(into: Data(#"{"theme":"dark"}"#.utf8)))
        let root = json(result.settings)
        #expect(root["theme"] as? String == "dark")
        #expect((root["statusLine"] as? [String: Any])?["command"] as? String == StatusLineMerger.command)
        #expect((root["statusLine"] as? [String: Any])?["type"] as? String == "command")
        #expect(result.original == nil)
        #expect(StatusLineMerger.chainCommand(of: result.original) == nil)
        #expect(StatusLineMerger.status(in: result.settings) == .installed)
        // Removal drops the key again.
        let removed = try #require(try StatusLineMerger.remove(from: result.settings, original: nil))
        #expect(json(removed) as NSDictionary == ["theme": "dark"] as NSDictionary)
    }

    @Test func existingCommandIsChainedAndKeepsItsOptions() throws {
        let original = #"{"statusLine":{"type":"command","command":"~/.claude/my-line.sh --fancy","padding":2}}"#
        let result = try #require(try StatusLineMerger.install(into: Data(original.utf8)))
        let entry = try #require(json(result.settings)["statusLine"] as? [String: Any])
        #expect(entry["command"] as? String == StatusLineMerger.command)
        #expect(entry["padding"] as? Int == 2)
        #expect(StatusLineMerger.chainCommand(of: result.original) == "~/.claude/my-line.sh --fancy")
        // The sidecar round-trips the original exactly.
        let stored = try StatusLineMerger.decodeOriginal(try StatusLineMerger.encodeOriginal(result.original))
        #expect(stored as? NSDictionary == ["type": "command", "command": "~/.claude/my-line.sh --fancy", "padding": 2] as NSDictionary)
        // Remove restores it exactly.
        let removed = try #require(try StatusLineMerger.remove(from: result.settings, original: stored))
        #expect(json(removed) as NSDictionary == json(Data(original.utf8)) as NSDictionary)
    }

    @Test func installingTwiceChangesNothingAndForeignStatusLineIsNotRemoved() throws {
        let first = try #require(try StatusLineMerger.install(into: nil))
        #expect(try StatusLineMerger.install(into: first.settings) == nil) // already ours: no write
        // The user replaced it with their own since: remove must not touch it.
        let theirs = Data(#"{"statusLine":{"type":"command","command":"echo mine"}}"#.utf8)
        #expect(try StatusLineMerger.remove(from: theirs, original: nil) == nil)
        #expect(throws: ClaudeSettingsMerger.MergeError.self) { _ = try StatusLineMerger.install(into: Data("{ nope".utf8)) }
    }

    // MARK: file level

    @Test func installerRoundTripRestoresOriginalFile() throws {
        let original = """
        {"theme":"dark","statusLine":{"type":"command","command":"printf 'mine'","padding":0},"hooks":{"Stop":[]}}
        """
        let (home, paths) = try setUp(original); defer { try? FileManager.default.removeItem(at: home) }
        let installer = StatusLineInstaller(paths: paths)

        try installer.install()
        #expect(installer.isInstalled)
        #expect(installer.chainMatchesOriginal())
        #expect(try String(contentsOf: paths.statusLineChain, encoding: .utf8) == "printf 'mine'")
        #expect(try statusCommand(paths) == StatusLineMerger.command)
        let afterFirst = try Data(contentsOf: paths.claudeSettings)
        let originalSidecar = try Data(contentsOf: paths.statusLineOriginal)

        // Twice: nothing changes, the stored original is not overwritten with our own entry.
        try installer.install()
        #expect(try Data(contentsOf: paths.claudeSettings) == afterFirst)
        #expect(try Data(contentsOf: paths.statusLineOriginal) == originalSidecar)

        try installer.remove()
        #expect(try settings(paths) as NSDictionary == json(Data(original.utf8)) as NSDictionary)
        #expect(!installer.isInstalled)
        for url in [paths.statusLineScript, paths.statusLineOriginal, paths.statusLineChain] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: paths.claudeSettings.deletingLastPathComponent().path)
            .filter { $0.contains("vigil-backup") }
        #expect(!backups.isEmpty)
    }

    @Test func installerWithoutPreviousStatusLineRemovesTheKey() throws {
        let (home, paths) = try setUp(#"{"theme":"dark"}"#); defer { try? FileManager.default.removeItem(at: home) }
        let installer = StatusLineInstaller(paths: paths)
        try installer.install()
        #expect(try String(contentsOf: paths.statusLineOriginal, encoding: .utf8) == "null")
        #expect(try String(contentsOf: paths.statusLineChain, encoding: .utf8) == "")
        try installer.remove()
        #expect(try settings(paths) as NSDictionary == ["theme": "dark"] as NSDictionary)
    }

    @Test func invalidSettingsAreLeftUntouched() throws {
        let broken = "{ not json"
        let (home, paths) = try setUp(broken); defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: InstallError.self) { try StatusLineInstaller(paths: paths).install() }
        #expect(try String(contentsOf: paths.claudeSettings, encoding: .utf8) == broken)
        #expect(!FileManager.default.fileExists(atPath: paths.statusLineOriginal.path))
    }

    @Test func driftedChainIsRepairedOnReinstall() throws {
        let (home, paths) = try setUp(#"{"statusLine":{"type":"command","command":"echo a"}}"#)
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = StatusLineInstaller(paths: paths)
        try installer.install()
        try "echo tampered".write(to: paths.statusLineChain, atomically: true, encoding: .utf8)
        #expect(!installer.chainMatchesOriginal())
        try installer.install()
        #expect(installer.chainMatchesOriginal())
    }

    // MARK: the real wrapper script

    private func runWrapper(_ script: String, input: String, socket: String, chain: String, extraEnv: [String: String] = [:]) -> (ShellResult, TimeInterval) {
        var env = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "VIGIL_SOCKET": socket, "VIGIL_STATUSLINE_CHAIN": chain]
        env.merge(extraEnv) { $1 }
        let start = Date()
        let r = Shell.run("/bin/sh", [script], stdin: input, environment: env, timeout: 5)
        return (r, Date().timeIntervalSince(start))
    }

    @Test func wrapperForwardsChainsAndSummarizes() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("statusline.sh")
        try StatusLineScript.contents(weekLabel: "week").write(to: script, atomically: true, encoding: .utf8)
        let chain = dir.appendingPathComponent("chain")
        let sock = "/tmp/vgl-\(UUID().uuidString.prefix(8)).sock"
        let box = SnapshotBox()
        let server = HookServer(socketPath: sock, onStatusLine: { box.add($0) }) { _ in }
        try server.start()
        defer { server.stop() }

        let input = #"{"session_id":"w1","cwd":"/p","model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":42.4,"resets_at":1790000000},"seven_day":{"used_percentage":15,"resets_at":1790400000}}}"#

        // No previous status line: forwards and prints the short line.
        try "".write(to: chain, atomically: true, encoding: .utf8)
        let (plain, elapsed) = runWrapper(script.path, input: input, socket: sock, chain: chain.path)
        #expect(plain.status == 0)
        #expect(plain.stdout == "Claude 42 % · week 15 %\n")
        #expect(elapsed < 1.5)
        #expect(box.waitForCount(1))
        #expect(box.all.first?.sessionID == "w1")
        #expect(box.all.first?.fiveHour?.usedPercentage == 42.4)

        // A previous command gets the same stdin and its output is printed unchanged.
        try #"read -r line; printf 'mine:%s' "$(printf '%s' "$line" | /usr/bin/cut -c1-14)"; exit 3"#
            .write(to: chain, atomically: true, encoding: .utf8)
        let (chained, _) = runWrapper(script.path, input: input, socket: sock, chain: chain.path)
        #expect(chained.status == 0) // the wrapper always exits 0, even if the original fails
        #expect(chained.stdout == #"mine:{"session_id":"#)
        #expect(box.waitForCount(2))

        // The self-test flag skips the user's command.
        let (selfTest, _) = runWrapper(script.path, input: input, socket: sock, chain: chain.path, extraEnv: ["VIGIL_STATUSLINE_SELFTEST": "1"])
        #expect(selfTest.stdout.hasPrefix("Claude 42 %"))

        // Without rate_limits: model name. Without Vigil running: still prints, still exits 0.
        let (noLimits, _) = runWrapper(script.path, input: #"{"session_id":"w2","model":{"display_name":"Opus 5.5"}}"#,
                                       socket: "/tmp/vgl-missing.sock", chain: "/nonexistent")
        #expect(noLimits.status == 0)
        #expect(noLimits.stdout == "Claude · Opus 5.5\n")
        let (empty, _) = runWrapper(script.path, input: "", socket: "/tmp/vgl-missing.sock", chain: "/nonexistent")
        #expect(empty.status == 0 && empty.stdout == "Claude\n")
    }

    @Test func hookEventsStillReachTheHookHandler() throws {
        let sock = "/tmp/vgl-\(UUID().uuidString.prefix(8)).sock"
        let hooks = EventBox(), lines = SnapshotBox()
        let server = HookServer(socketPath: sock, onStatusLine: { lines.add($0) }) { hooks.add($0) }
        try server.start()
        defer { server.stop() }
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let hook = dir.appendingPathComponent("hook.sh")
        try HookScript.contents.write(to: hook, atomically: true, encoding: .utf8)
        _ = Shell.run("/bin/sh", [hook.path, "Stop"], stdin: #"{"session_id":"h1"}"#,
                      environment: ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "VIGIL_SOCKET": sock], timeout: 5)
        #expect(hooks.waitForCount(1))
        #expect(hooks.all.first?.kind == .stop)
        #expect(lines.all.isEmpty)
    }
}

@Suite struct SettingsDecodingTests {
    @Test func oldSettingsLoadWithNewDefaults() throws {
        let suite = "vigil-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Saved before the UI settings existed: nothing may reset to defaults.
        let old = #"{"enabled":false,"hasSeenOnboarding":true,"dryRun":true,"revision":2,"config":{"graceSeconds":120}}"#
        defaults.set(Data(old.utf8), forKey: "vigil.settings.v1")
        let loaded = SettingsStore(defaults: defaults).load()
        #expect(loaded.enabled == false)
        #expect(loaded.dryRun == true)
        #expect(loaded.hasSeenOnboarding)
        #expect(loaded.config.graceSeconds == 120)
        #expect(loaded.ui == UISettings())
        #expect(loaded.ui.notchEnabled && loaded.ui.hideInFullScreen && loaded.ui.usageNotifications)
        #expect(loaded.ui.shortcut == HotKeySpec(enabled: true, keyCode: 32, modifiers: 0x0900))

        var changed = loaded
        changed.ui.accent = .purple
        changed.ui.notchPosition = 0.3
        changed.ui.notchDisplays = .main
        SettingsStore(defaults: defaults).save(changed)
        #expect(SettingsStore(defaults: defaults).load() == changed)
    }
}

/// Thread-safe collector for status line snapshots arriving from the socket server.
final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [StatusLineSnapshot] = []
    func add(_ s: StatusLineSnapshot) { lock.withLock { items.append(s) } }
    var all: [StatusLineSnapshot] { lock.withLock { items } }
    func waitForCount(_ n: Int, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if all.count >= n { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return all.count >= n
    }
}
