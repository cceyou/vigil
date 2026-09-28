import Foundation
import Testing
@testable import VigilCore

@Suite struct MiscTests {
    @Test func sleepDisabledParsing() {
        let on = " Sleep On Power Button 1\n SleepDisabled\t\t1\n sleep 1\n"
        let off = " SleepDisabled\t\t0\n"
        #expect(parseSleepDisabled(pmsetOutput: on) == true)
        #expect(parseSleepDisabled(pmsetOutput: off) == false)
        #expect(parseSleepDisabled(pmsetOutput: "sleep 1\n") == nil)
    }

    @Test func sudoersRuleAllowsExactlyTwoCommands() {
        let rule = SudoersInstaller.rule(for: "alice")
        #expect(rule.contains("alice ALL = (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"))
        #expect(!rule.contains("ALL, "))
        #expect(!rule.contains("pmset *"))
    }

    @Test func sudoersRuleIsAcceptedByVisudo() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("vigil")
        try SudoersInstaller.rule(for: "alice").write(to: file, atomically: true, encoding: .utf8)
        #expect(Shell.run("/usr/sbin/visudo", ["-cf", file.path]).ok)
        // ...and a broken rule is rejected, so a bad file can never be installed.
        try "alice ALL = NOPASSWD /usr/bin/pmset".write(to: file, atomically: true, encoding: .utf8)
        #expect(!Shell.run("/usr/sbin/visudo", ["-cf", file.path]).ok)
    }

    @Test func sudoersRejectsUnsafeUserNames() {
        #expect(SudoersInstaller.isValidUserName("krystofchmela"))
        #expect(SudoersInstaller.isValidUserName("first.last-2"))
        for bad in ["", "a b", "a;b", "a\nb", "root ALL=(ALL) NOPASSWD: ALL #"] {
            #expect(!SudoersInstaller.isValidUserName(bad))
        }
    }

    @Test func historyKeepsLast50NewestFirst() {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(url: dir.appendingPathComponent("history.json"))
        for i in 0..<60 {
            store.append(SessionRecord(id: "s\(i)", project: "p", startedAt: at(Double(i)), duration: Double(i), reason: .ended))
        }
        let list = store.load()
        #expect(list.count == 50)
        #expect(list.first?.id == "s59")
        #expect(list.last?.id == "s10")
        // survives a reload from disk
        #expect(HistoryStore(url: dir.appendingPathComponent("history.json")).load().count == 50)
    }

    @Test func settingsRoundTrip() {
        let suite = UserDefaults(suiteName: "vigil-test-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        #expect(store.load() == AppSettings())
        var s = AppSettings()
        s.enabled = false
        s.config.graceSeconds = 90
        s.config.notificationPolicy = .keepAwake
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func watchdogScriptRestoresOnlyWhenArmed() {
        let script = SystemPowerController.watchdogScript(appPID: 4242, appName: "Vigil", armFile: "/tmp/x/watchdog.armed")
        #expect(script.contains("ps -p 4242"))
        #expect(script.contains("if [ -e '/tmp/x/watchdog.armed' ]"))
        #expect(script.contains("sudo -n /usr/bin/pmset -a disablesleep 0"))
    }

    @Test func watchdogRestoresAfterAppDiesButNotIfDisarmed() throws {
        // Run the real watchdog script against a stand-in "app" and a fake sudo that records its call.
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let arm = dir.appendingPathComponent("armed")
        let log = dir.appendingPathComponent("calls.log")

        func run(armed: Bool) throws -> String {
            try? FileManager.default.removeItem(at: log)
            if armed { FileManager.default.createFile(atPath: arm.path, contents: Data()) } else { try? FileManager.default.removeItem(at: arm) }
            let app = Process()
            app.executableURL = URL(fileURLWithPath: "/bin/sleep"); app.arguments = ["30"]
            try app.run()
            // Same script text, but sudo replaced by a logger so we never touch pmset.
            var script = SystemPowerController.watchdogScript(appPID: app.processIdentifier, appName: "sleep", armFile: arm.path)
            script = script.replacingOccurrences(of: "/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0",
                                                 with: "echo restored >> '\(log.path)'")
            let wd = Process()
            wd.executableURL = URL(fileURLWithPath: "/bin/sh"); wd.arguments = ["-c", script]
            try wd.run()
            Thread.sleep(forTimeInterval: 0.5)
            #expect(wd.isRunning) // still waiting while the app is alive
            app.terminate(); app.waitUntilExit()
            wd.waitUntilExit()   // exits by itself once the app is gone
            return (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        }
        #expect(try run(armed: true).contains("restored"))
        #expect(try run(armed: false).isEmpty)
    }

    @Test func dryRunNeverTouchesPmset() async throws {
        let power = DryRunPowerController()
        try await power.acquireAwake()
        #expect(power.sleepDisabled() == true)
        _ = await power.releaseAwake()
        await power.sleepNow()
        #expect(power.sleepDisabled() == false)
        #expect(power.recorded == ["would run: pmset -a disablesleep 1", "would run: pmset -a disablesleep 0", "would run: pmset sleepnow"])
    }

    @Test func projectNameFromCwd() {
        let s = Session(id: "1", cwd: "/Users/me/Projects/alwayson", pid: nil, state: .idle, startedAt: t0, lastEventAt: t0, stateSince: t0)
        #expect(s.projectName == "alwayson")
        var none = s; none.cwd = nil
        #expect(none.projectName == "Claude Code")
    }

    @Test func logRotates() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = Log(paths: VigilPaths(home: dir))
        let big = String(repeating: "x", count: 100_000)
        for _ in 0..<25 { log.info(big) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(atPath: VigilPaths(home: dir).logDir.path)
        #expect(files.contains("vigil.log"))
        #expect(files.contains("vigil.1.log"))
        #expect(files.count <= 3)
    }
}
