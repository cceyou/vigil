import Foundation
import Testing
@testable import VigilCore

@Suite struct ShellProcessTests {
    /// How Claude Code 2.1.314 runs `sleep 90; echo probe-done` in the background (seen with ps on this machine).
    private func table(cpu: TimeInterval = 0, sleepAlive: Bool = true, extra: [ProcessEntry] = []) -> [ProcessEntry] {
        var t = [
            ProcessEntry(pid: 100, ppid: 1, args: "claude", cpuTime: 50),
            ProcessEntry(pid: 101, ppid: 100, args: "caffeinate -i -t 300", cpuTime: 0),
            ProcessEntry(pid: 102, ppid: 100, args: "node /x/mcp-server/index.js", cpuTime: 9),
            ProcessEntry(pid: 110, ppid: 100, args: "/bin/zsh -c source /Users/me/.claude/shell-snapshots/snapshot-zsh-1.sh 2>/dev/null || true "
                         + "&& setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval 'sleep 90; echo probe-done' < /dev/null && pwd -P >| /tmp/cwd",
                         cpuTime: 0.01),
        ]
        if sleepAlive { t.append(ProcessEntry(pid: 111, ppid: 110, args: "sleep 90", cpuTime: cpu)) }
        return t + extra
    }

    private let session = ShellProcessTracker.SessionInfo(id: "s", pid: 100, shells: [(id: "b1", command: "sleep 90; echo probe-done")])

    @Test func findsTheWrapperShellAndSeesItEnd() {
        var tracker = ShellProcessTracker(window: 300)
        let first = tracker.observe(table(), sessions: [session], at: at(0))
        #expect(first == [ProcessObservation(sessionID: "s", activity: false, shells: ["b1": ShellObservation(found: true)])])
        // The wrapper and its child are gone: the shell has ended.
        let gone = table(sleepAlive: false).filter { $0.pid != 110 }
        let last = tracker.observe(gone, sessions: [session], at: at(5))
        #expect(last.first?.shells["b1"] == ShellObservation(found: false, exited: true))
        #expect(last.first?.activity == true) // the session's processes changed
    }

    @Test func averagesCPUOverTheWindowOnly() {
        var tracker = ShellProcessTracker(window: 300)
        _ = tracker.observe(table(cpu: 0), sessions: [session], at: at(0))
        #expect(tracker.observe(table(cpu: 1), sessions: [session], at: at(100)).first?.shells["b1"]?.cpuPercent == nil)
        // 6 s of CPU over 300 s = 2 %.
        let pct = tracker.observe(table(cpu: 6), sessions: [session], at: at(300)).first?.shells["b1"]?.cpuPercent
        #expect(pct.map { abs($0 - 2) < 0.01 } == true)
    }

    @Test func helpersAndClaudeItselfAreNotActivity() {
        var tracker = ShellProcessTracker()
        _ = tracker.observe(table(), sessions: [session], at: at(0))
        // MCP server and Claude burn CPU, caffeinate restarts: no activity.
        var t = table()
        t[0].cpuTime += 30
        t[2].cpuTime += 30
        t[1] = ProcessEntry(pid: 105, ppid: 100, args: "caffeinate -i -t 300", cpuTime: 0)
        #expect(tracker.observe(t, sessions: [session], at: at(5)).first?.activity == false)
        // A new process under the shell is.
        let more = table(extra: [ProcessEntry(pid: 112, ppid: 110, args: "gh run view 1", cpuTime: 0.05)])
        #expect(tracker.observe(more, sessions: [session], at: at(10)).first?.activity == true)
    }

    @Test func quotesInTheCommandStillMatch() {
        let cmd = #"echo "it's done" && sleep 5"#
        let wrapper = ProcessEntry(pid: 120, ppid: 100, args: #"/bin/zsh -c source x && eval 'echo "it'\''s done" && sleep 5' < /dev/null"#, cpuTime: 0)
        var tracker = ShellProcessTracker()
        let s = ShellProcessTracker.SessionInfo(id: "s", pid: 100, shells: [(id: "q", command: cmd)])
        #expect(tracker.observe([ProcessEntry(pid: 100, ppid: 1, args: "claude", cpuTime: 0), wrapper], sessions: [s], at: at(0))
                    .first?.shells["q"]?.found == true)
    }

    @Test func readsThisProcessFromTheRealTable() {
        let me = ProcessInfo.processInfo.processIdentifier
        let rows = ProcessTableReader.descendants(of: [me])
        #expect(rows.first { $0.pid == me }.map { !$0.args.isEmpty && $0.cpuTime > 0 } == true)
    }
}

@Suite struct ChimeShellTests {
    final class FakePlayer: SoundPlaying {
        var played: [String] = []
        func play(_ sound: String, volume: Double) { played.append(sound) }
    }

    @Test func noDoneSoundWhileAShellRunsThenOneWhenItEnds() {
        var settings = SoundSettings()
        settings.minTurnDuration = 0
        let player = FakePlayer()
        let chime = ChimeMachine(settings: settings, player: player)
        var m = machine()
        func send(_ e: Event, _ t: TimeInterval) -> [ChimeCue] {
            let before = m.sessions
            let was = Dictionary(before.map { ($0.id, m.busyForChime($0)) }, uniquingKeysWith: { a, _ in a })
            _ = m.handle(e, at: at(t))
            let after = m
            return chime.observe(e, before: before, after: m.sessions, at: at(t), wasBusy: { was[$0.id] ?? false },
                                 isBusy: { after.busyForChime($0) })
        }
        _ = send(.hook(HookEvent(kind: .userPromptSubmit, sessionID: "a", pid: 100)), 0)
        _ = send(.hook(HookEvent(kind: .postToolUse, sessionID: "a", pid: 100,
                                 startedShell: ReportedTask(id: "b", kind: .shell, command: "npm test"))), 5)
        #expect(send(.hook(HookEvent(kind: .stop, sessionID: "a", backgroundTasks: [ReportedTask(id: "b", kind: .shell, command: "npm test")])), 10).isEmpty)
        _ = send(.processes([ProcessObservation(sessionID: "a", activity: false, shells: ["b": ShellObservation(found: true)])]), 15)
        #expect(send(.processes([ProcessObservation(sessionID: "a", activity: true, shells: ["b": ShellObservation(found: false, exited: true)])]), 60) == [.done])
        #expect(player.played.count == 1)
    }
}

@Suite(.serialized) struct HookScriptPIDTests {
    /// A background session: claude daemon → "claude bg-pty-host" → "claude bg-spare" → hook. The hook must report
    /// the bg-spare process (the session), never the pty host or the daemon. Two sessions at once get two PIDs.
    @Test func backgroundSessionsReportTheirOwnProcess() throws {
        let dir = makeTempDir("vgl-bg"); defer { try? FileManager.default.removeItem(at: dir) }
        let sock = "/tmp/vgl-\(UUID().uuidString.prefix(8)).sock"
        let box = EventBox()
        let server = HookServer(socketPath: sock) { box.add($0) }
        try server.start()
        defer { server.stop() }
        let hook = dir.appendingPathComponent("hook.sh")
        try HookScript.contents.write(to: hook, atomically: true, encoding: .utf8)
        // macOS ps shows argv[0] as the process name, and Claude Code sets it ("claude bg-spare"); `exec -a` does
        // the same for bash. Each level keeps running while its child runs ("; true" stops bash from exec'ing it).
        func run(_ session: String) -> Int32? {
            let pidFile = dir.appendingPathComponent("\(session).pid").path
            let env = [
                "SPARE": #"echo $$ > "$PIDFILE"; /bin/sh "$HOOK" Stop; true"#,
                "TOSPARE": #"exec -a "claude bg-spare" /bin/bash -c "$SPARE""#,
                "PTY": #"/bin/bash -c "$TOSPARE"; true"#,
                "TOPTY": #"exec -a "claude bg-pty-host" /bin/bash -c "$PTY""#,
                "DAEMON": #"/bin/bash -c "$TOPTY"; true"#,
                "HOOK": hook.path, "PIDFILE": pidFile, "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "VIGIL_SOCKET": sock,
            ]
            let r = Shell.run("/bin/bash", ["-c", #"exec -a claude /bin/bash -c "$DAEMON""#],
                              stdin: #"{"session_id":"\#(session)","hook_event_name":"Stop"}"#, environment: env, timeout: 10)
            guard r.status == 0 else { return nil }
            return (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let one = try #require(run("bg-one"))
        let two = try #require(run("bg-two"))
        #expect(box.waitForCount(2))
        let pids = Dictionary(box.all.map { ($0.sessionID, $0.pid) }, uniquingKeysWith: { a, _ in a })
        #expect(pids["bg-one"] == one)
        #expect(pids["bg-two"] == two)
        #expect(one != two)
    }
}
