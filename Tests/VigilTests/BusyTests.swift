import Foundation
import Testing
@testable import VigilCore

/// The derived busy state: turn, subagents, background shells (from `background_tasks`), recent activity, the
/// silence failsafe and the 12-hour limit. Replays real payloads from Fixtures/hooks.
@Suite struct BusyTests {
    /// The default config (2-minute activity window, 30-minute silence failsafe, 12-hour limit) with a 30 s grace.
    private func live(_ configure: (inout Config) -> Void = { _ in }) -> StateMachine {
        var c = Config()
        c.graceSeconds = 30
        configure(&c)
        return StateMachine(enabled: true, config: c, presence: .away)
    }

    private func event(_ kind: HookKind, _ id: String = "a", pid: Int32? = 100, agent: String? = nil, type: String? = nil,
                       source: String? = nil, tasks: [ReportedTask]? = nil, shell: ReportedTask? = nil,
                       ended: [String] = []) -> Event {
        .hook(HookEvent(kind: kind, sessionID: id, cwd: "/Users/me/proj", pid: pid, agentID: agent, agentType: type,
                        source: source, backgroundTasks: tasks, startedShell: shell, endedTaskIDs: ended))
    }

    private func shell(_ id: String, _ command: String, status: String = "running") -> ReportedTask {
        ReportedTask(id: id, kind: .shell, status: status, command: command)
    }

    private func agent(_ id: String) -> ReportedTask { ReportedTask(id: id, kind: .subagent, agentType: "general-purpose") }

    // MARK: recorded payloads

    private func recorded() throws -> [(HookEvent, Date)] {
        let url = try #require(Bundle.module.url(forResource: "background-shell-and-agent", withExtension: "json",
                                                 subdirectory: "Fixtures/hooks"))
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let events = try #require(root["events"] as? [[String: Any]])
        let iso = ISO8601DateFormatter()
        // PreToolUse is in the recording but not a hook Vigil registers.
        return try events.filter { $0["event"] as? String != "PreToolUse" }.map { e in
            let line = try JSONSerialization.data(withJSONObject: ["vigil_event": e["event"]!, "pid": 4242, "payload": e["payload"]!])
            let parsed = try #require(HookEventParser.parse(line))
            return (parsed, try #require(iso.date(from: e["at"] as! String)))
        }
    }

    @Test func recordedPayloadsParse() throws {
        let events = try recorded().map(\.0)
        let bash = try #require(events.first { $0.kind == .postToolUse && $0.toolName == "Bash" && $0.agentID == nil })
        #expect(bash.startedShell == ReportedTask(id: "bikyf6aup", kind: .shell, command: "sleep 40; echo shell-done",
                                                  description: "Background sleep then echo shell-done"))
        let stops = events.filter { $0.kind == .stop }
        #expect(stops.count == 3)
        #expect(stops[0].backgroundTasks?.map(\.id) == ["a70defc60dd15ed99", "bikyf6aup"])
        #expect(stops[0].backgroundTasks?.map(\.kind) == [.subagent, .shell])
        #expect(stops[1].backgroundTasks?.map(\.id) == ["bikyf6aup"])
        #expect(stops[2].backgroundTasks == [])
        let prompts = events.filter { $0.kind == .userPromptSubmit }
        #expect(prompts.map(\.endedTaskIDs) == [[], [], ["bikyf6aup"]]) // the prompt, the agent's hand-back, the shell's notification
        let subStop = try #require(events.first { $0.kind == .subagentStop })
        #expect(subStop.agentID == "a70defc60dd15ed99")
        #expect(subStop.backgroundTasks?.count == 2) // still lists the stopping agent itself
    }

    @Test func recordedRunStaysBusyUntilTheLastBackgroundTaskEnds() throws {
        var m = live()
        var busyAtStop: [Bool] = []
        for (e, date) in try recorded() {
            _ = m.handle(.hook(e), at: date)
            if e.kind == .stop {
                // Judged right after the Stop and again after the 2-minute activity window.
                let s = try #require(m.sessions.first)
                busyAtStop.append(m.busyReasons(s).contains { $0 != .recentActivity })
            }
        }
        // Stop 1: agent + shell running. Stop 2 (auto-continued after the agent's hand-back): shell running.
        // Stop 3 (after the shell's task-notification): nothing left.
        #expect(busyAtStop == [true, true, false])
        #expect(m.sessions[0].shells.isEmpty && m.sessions[0].subagents.isEmpty)
    }

    // MARK: shells

    @Test func stopWhileABackgroundShellRunsStaysBusy() {
        var m = live { $0.recentActivityWindow = 0 }
        _ = m.handle(event(.userPromptSubmit), at: at(0))
        _ = m.handle(event(.postToolUse, shell: shell("b1", "npm test")), at: at(5))
        _ = m.handle(event(.stop, tasks: [shell("b1", "npm test")]), at: at(10))
        // Long after the activity window: still busy, no countdown, for as long as it runs (CPU does not matter).
        _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: true, shells: ["b1": ShellObservation(found: true, cpuPercent: 0)])]),
                     at: at(1200))
        #expect(m.handle(.tick, at: at(1300)).isEmpty)
        #expect(m.phase == .working)
        #expect(m.busyReasons(m.sessions[0]) == [.shell("npm test")])
        // Its process ends: the grace period starts.
        let fx = m.handle(.processes([ProcessObservation(sessionID: "a", activity: true, shells: ["b1": ShellObservation(found: false, exited: true)])]),
                          at: at(1400))
        #expect(fx == [.showCountdown(deadline: at(1430))])
    }

    @Test func aZeroCPUWaitLoopKeepsTheMacAwake() {
        // The `until gh run view …; do sleep 30; done` of 28 Oct: almost no CPU, but real work. Not a server.
        let loop = "until [ \"$(gh run view 1 --json status -q .status)\" = \"completed\" ]; do sleep 30; done"
        #expect(!ServerCommands.isServer(loop))
        var m = live()
        _ = m.handle(event(.postToolUse, shell: shell("b1", loop)), at: at(0))
        _ = m.handle(event(.stop, tasks: [shell("b1", loop)]), at: at(1))
        for t in stride(from: 60.0, through: 1800, by: 60) {
            // Every sample sees gh come and go (a process change) at ~0 % CPU.
            _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: true,
                                                        shells: ["b1": ShellObservation(found: true, cpuPercent: 0.1)])]), at: at(t))
            _ = m.handle(.tick, at: at(t))
            #expect(m.phase == .working)
        }
    }

    @Test func anIdleDevServerStopsCountingAfterFiveMinutes() {
        var m = live()
        _ = m.handle(event(.postToolUse, shell: shell("dev", "pnpm run dev")), at: at(0))
        _ = m.handle(event(.stop, tasks: [shell("dev", "pnpm run dev")]), at: at(2))
        _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: false, shells: ["dev": ShellObservation(found: true)])]), at: at(60))
        #expect(m.handle(.tick, at: at(200)).isEmpty)
        #expect(m.phase == .working) // under 5 minutes it counts
        let fx = m.handle(.processes([ProcessObservation(sessionID: "a", activity: false,
                                                         shells: ["dev": ShellObservation(found: true, cpuPercent: 0.4)])]), at: at(301))
        #expect(fx == [.showCountdown(deadline: at(331))])
        #expect(m.activeShells(m.sessions[0]).isEmpty)
        // A busy server (a rebuild) counts again.
        #expect(m.handle(.processes([ProcessObservation(sessionID: "a", activity: true,
                                                        shells: ["dev": ShellObservation(found: true, cpuPercent: 12)])]), at: at(320))
                == [.dismissCountdown])
    }

    @Test func shellPolicies() {
        func busy(_ policy: BackgroundShellPolicy, _ command: String) -> Bool {
            var m = live { $0.backgroundShells = policy; $0.recentActivityWindow = 0 }
            _ = m.handle(event(.stop, tasks: [shell("s", command)]), at: at(0))
            _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: false, shells: ["s": ShellObservation(found: true, cpuPercent: 0)])]),
                         at: at(400))
            return !m.busyReasons(m.sessions[0]).isEmpty
        }
        #expect(busy(.exceptServers, "pytest -x"))
        #expect(!busy(.exceptServers, "stripe listen --forward-to localhost:3000"))
        #expect(busy(.always, "stripe listen --forward-to localhost:3000"))
        #expect(!busy(.ignore, "pytest -x"))
    }

    @Test func ignoringAShellLetsTheMacSleep() {
        var m = live { $0.recentActivityWindow = 0 }
        _ = m.handle(event(.stop, tasks: [shell("s", "sleep 300")]), at: at(0))
        #expect(m.phase == .working)
        #expect(m.handle(.ignoreShell(sessionID: "a", shellID: "s"), at: at(10)) == [.showCountdown(deadline: at(40))])
    }

    @Test func taskNotificationAndTaskStopEndShells() {
        var m = live { $0.recentActivityWindow = 0 }
        _ = m.handle(event(.postToolUse, shell: shell("s1", "make")), at: at(0))
        _ = m.handle(event(.postToolUse, shell: shell("s2", "make test")), at: at(1))
        _ = m.handle(event(.userPromptSubmit, ended: ["s1"]), at: at(10))
        #expect(m.sessions[0].shells.map(\.id) == ["s2"])
        _ = m.handle(event(.postToolUse, ended: ["s2"]), at: at(11))
        #expect(m.sessions[0].shells.isEmpty)
    }

    // MARK: agents and auto-continued turns

    @Test func aBackgroundAgentWithoutUserPromptSubmitIsBusy() {
        // An agent started from the agents view, or one Vigil first sees mid-run: its tool calls carry agent_id.
        var m = live { $0.recentActivityWindow = 0 }
        _ = m.handle(event(.sessionStart, source: "startup"), at: at(0))
        _ = m.handle(event(.postToolUse, agent: "bg1", type: "general-purpose"), at: at(5))
        #expect(m.busyReasons(m.sessions[0]) == [.subagents(1)]) // adopted from its tool call
        _ = m.handle(event(.stop, tasks: [agent("bg1")]), at: at(6))
        #expect(m.busyReasons(m.sessions[0]) == [.subagents(1)])
        #expect(m.handle(.tick, at: at(900)).isEmpty)
        #expect(m.handle(event(.subagentStop, agent: "bg1", type: "general-purpose"), at: at(1000)) == [.showCountdown(deadline: at(1030))])
        // A late tool call of the finished agent does not bring it back.
        _ = m.handle(event(.postToolUse, agent: "bg1", type: "general-purpose"), at: at(1001))
        #expect(m.sessions[0].subagents.isEmpty)
    }

    @Test func anAutoContinuedTurnIsBusy() {
        var m = live { $0.recentActivityWindow = 0 }
        _ = m.handle(event(.userPromptSubmit), at: at(0))
        _ = m.handle(event(.stop, tasks: [shell("s", "sleep 40")]), at: at(5))
        // The shell ends; Claude Code feeds the notification back and Claude goes on by itself.
        _ = m.handle(event(.userPromptSubmit, ended: ["s"]), at: at(45))
        #expect(m.busyReasons(m.sessions[0]) == [.turn])
        #expect(m.phase == .working)
        #expect(m.handle(event(.stop, tasks: []), at: at(60)) == [.showCountdown(deadline: at(90))])
    }

    @Test func aSubagentStillRunningAfterStopIsBusyAndLostOnesAreDropped() {
        var m = live { $0.recentActivityWindow = 0 }
        _ = m.handle(event(.userPromptSubmit), at: at(0))
        _ = m.handle(event(.subagentStart, agent: "fg", type: "Explore"), at: at(1))
        _ = m.handle(event(.subagentStart, agent: "bg", type: "general-purpose"), at: at(2))
        // fg lost its SubagentStop; background_tasks at Stop lists only bg.
        _ = m.handle(event(.stop, tasks: [agent("bg")]), at: at(30))
        #expect(m.sessions[0].subagents.map(\.id) == ["bg"])
        #expect(m.phase == .working)
        #expect(m.handle(event(.subagentStop, agent: "bg", type: "general-purpose"), at: at(60)) == [.showCountdown(deadline: at(90))])
    }

    // MARK: activity, compaction, silence, limit

    @Test func activityAloneMakesASessionBusyForTwoMinutes() {
        var m = live()
        _ = m.handle(event(.userPromptSubmit), at: at(0))
        _ = m.handle(event(.postToolUse), at: at(10))
        _ = m.handle(event(.stop), at: at(11))
        #expect(m.busyReasons(m.sessions[0]) == [.recentActivity])
        #expect(m.phase == .working)
        // Two minutes after the last tool call the countdown starts.
        #expect(m.handle(.tick, at: at(130)) == [.showCountdown(deadline: at(160))])
        // A tool call during the countdown (an agent Vigil cannot otherwise see) cancels it.
        #expect(m.handle(event(.postToolUse), at: at(140)) == [.dismissCountdown])
        #expect(m.phase == .working)
        #expect(m.sessions[0].state == .idle) // activity is not a turn
    }

    @Test func compactionOf28OctoberCountsAsActivityAndResetsNothing() {
        // Replayed from Vigil's log of 28 Oct 2026, session ebbea94d (times relative to the Stop at 16:40:06).
        var m = live()
        _ = m.handle(event(.userPromptSubmit), at: at(-39))
        _ = m.handle(event(.stop), at: at(0))
        _ = m.handle(event(.notification).withNotificationType("idle_prompt"), at: at(60))
        _ = m.handle(event(.subagentStop, agent: "acd499fb"), at: at(183)) // Claude Code's away summary: no agent_type
        #expect(m.sessions[0].subagents.isEmpty)
        let afterSummary = m.sessions[0]
        _ = m.handle(.tick, at: at(190)) // the countdown has started (the away summary was not activity)
        #expect(m.phase == .countdown)
        _ = m.handle(.tick, at: at(400)) // and the Mac slept
        // 17:35:01 compaction: an internal SubagentStop, then SessionStart with source "compact".
        _ = m.handle(event(.subagentStop, agent: "af94af34"), at: at(3295))
        _ = m.handle(event(.sessionStart, source: "compact"), at: at(3296))
        let s = m.sessions[0]
        #expect(m.sessions.count == 1)
        #expect(s.id == afterSummary.id && s.startedAt == afterSummary.startedAt && s.state == .idle)
        #expect(m.busyReasons(s) == [.recentActivity]) // compaction is work, not a fresh start
        _ = m.handle(.tick, at: at(3416))
        #expect(m.busyReasons(m.sessions[0]).isEmpty)
        // resume and clear neither reset the session nor count as activity.
        var r = live()
        _ = r.handle(event(.userPromptSubmit), at: at(0))
        _ = r.handle(event(.sessionStart, source: "resume"), at: at(10))
        _ = r.handle(event(.sessionStart, source: "clear"), at: at(11))
        #expect(r.sessions[0].state == .working && r.sessions[0].stateSince == at(0))
        #expect(r.sessions[0].lastActivityAt == at(0))
    }

    @Test func silenceFailsafeEndsBusyWithoutActivityAndProcessChangesExtendIt() {
        var m = live()
        _ = m.handle(event(.stop, tasks: [shell("s", "sleep 3600")]), at: at(0))
        _ = m.handle(event(.postToolUse), at: at(0))
        // Process activity at 20 min pushes the failsafe to 50 min.
        _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: true)]), at: at(1200))
        #expect(m.handle(.tick, at: at(2999)).isEmpty)
        #expect(m.phase == .working)
        #expect(m.handle(.tick, at: at(3000)) == [.showCountdown(deadline: at(3030))])
        #expect(m.busyReasons(m.sessions[0]).isEmpty)
    }

    /// `sleep 2400` (or `gh run watch`): one quiet process, no new children, no CPU, no hooks for 40 minutes. Its
    /// process is alive in every sample, so the silence failsafe never cuts it; when it ends, the grace starts.
    @Test func aQuietShellWithALiveProcessOutlastsTheSilenceFailsafe() {
        var m = live()
        _ = m.handle(event(.postToolUse, shell: shell("s", "sleep 2400")), at: at(0))
        _ = m.handle(event(.stop, tasks: [shell("s", "sleep 2400")]), at: at(1))
        for t in stride(from: 5.0, to: 2400, by: 5) {
            _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: false, shells: ["s": ShellObservation(found: true)])]), at: at(t))
            #expect(m.handle(.tick, at: at(t)).power.isEmpty)
        }
        #expect(m.busyReasons(m.sessions[0]) == [.shell("sleep 2400")]) // 40 min after the last hook
        #expect(m.phase == .working)
        // The process ends: the session has nothing left, the grace starts once the activity window is over.
        _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: true, shells: ["s": ShellObservation(found: false, exited: true)])]), at: at(2400))
        #expect(m.sessions[0].shells.isEmpty)
        #expect(m.handle(.tick, at: at(2519)).isEmpty)
        #expect(m.handle(.tick, at: at(2520)) == [.showCountdown(deadline: at(2550))])
    }

    /// The failsafe still cuts what has no live process: a reported shell that was never found, a shell whose
    /// samples stopped, and a subagent whose SubagentStop never came.
    @Test func theSilenceFailsafeCutsSignalsWithoutALiveProcess() {
        var notFound = live()
        _ = notFound.handle(event(.stop, tasks: [shell("s", "sleep 3600")]), at: at(0))
        for t in stride(from: 5.0, to: 1800, by: 5) {
            _ = notFound.handle(.processes([ProcessObservation(sessionID: "a", activity: false, shells: ["s": ShellObservation(found: false)])]), at: at(t))
        }
        #expect(notFound.handle(.tick, at: at(1800)) == [.showCountdown(deadline: at(1830))])

        var stale = live()
        _ = stale.handle(event(.stop, tasks: [shell("s", "sleep 3600")]), at: at(0))
        _ = stale.handle(.processes([ProcessObservation(sessionID: "a", activity: false, shells: ["s": ShellObservation(found: true)])]), at: at(5))
        // No sample since 5 s (Vigil could not read the table): not "alive" any more, so the failsafe applies.
        #expect(stale.handle(.tick, at: at(1800)) == [.showCountdown(deadline: at(1830))])

        var agent = live()
        _ = agent.handle(event(.userPromptSubmit), at: at(0))
        _ = agent.handle(event(.subagentStart, agent: "x", type: "general-purpose"), at: at(1))
        _ = agent.handle(event(.stop, tasks: [self.agent("x")]), at: at(2))
        #expect(agent.busyReasons(agent.sessions[0]).contains(.subagents(1)))
        // SubagentStart at 1 s was the last activity; a Stop listing the agent is not activity.
        #expect(agent.handle(.tick, at: at(1800)).isEmpty)
        #expect(agent.handle(.tick, at: at(1801)) == [.showCountdown(deadline: at(1831))])
    }

    /// A live shell next to a stuck subagent: after the silence only the shell counts, and it keeps the Mac awake.
    @Test func afterTheSilenceOnlyTheLiveShellCounts() {
        var m = live()
        _ = m.handle(event(.subagentStart, agent: "x", type: "general-purpose"), at: at(0))
        _ = m.handle(event(.stop, tasks: [agent("x"), shell("s", "gh run watch 123")]), at: at(0))
        for t in stride(from: 5.0, through: 1900, by: 5) {
            _ = m.handle(.processes([ProcessObservation(sessionID: "a", activity: false, shells: ["s": ShellObservation(found: true)])]), at: at(t))
        }
        #expect(m.busyReasons(m.sessions[0]) == [.shell("gh run watch 123")])
        #expect(m.handle(.tick, at: at(1900)).power.isEmpty)
    }

    @Test func longWorkWithTheLidClosedRunsUntilTheTwelveHourLimit() {
        var m = live()
        _ = m.handle(event(.userPromptSubmit), at: at(0))
        // Busy for 11 h 59 min with a tool call every 10 minutes: never cut (the old limit was 2 h).
        for t in stride(from: 600.0, to: 12 * 3600, by: 600) {
            _ = m.handle(event(.postToolUse), at: at(t))
            #expect(m.handle(.tick, at: at(t + 1)).power.isEmpty)
        }
        let fx = m.handle(.tick, at: at(12 * 3600))
        #expect(fx.contains(.notifyGuard(.maxDuration)))
        #expect(fx.contains(.sleepNow))
    }

    @Test func countdownIsCancelledByAnyNewBusySignal() {
        let signals: [Event] = [
            .hook(HookEvent(kind: .userPromptSubmit, sessionID: "a")),
            .hook(HookEvent(kind: .subagentStart, sessionID: "a", agentID: "x")),
            .hook(HookEvent(kind: .postToolUse, sessionID: "a", pid: 100, startedShell: ReportedTask(id: "s", kind: .shell, command: "make"))),
            .hook(HookEvent(kind: .postToolUse, sessionID: "a", pid: 100)),
        ]
        for signal in signals {
            var m = live()
            _ = m.handle(event(.userPromptSubmit), at: at(0))
            _ = m.handle(event(.stop), at: at(1))
            _ = m.handle(.tick, at: at(121))
            #expect(m.phase == .countdown)
            #expect(m.handle(signal, at: at(130)) == [.dismissCountdown])
            #expect(m.phase == .working)
        }
    }

    @Test func defaultsAndMigration() throws {
        let c = Config()
        #expect(c.maxKeepAwake == 12 * 3600 && c.silenceLimit == 1800 && c.recentActivityWindow == 120)
        #expect(c.backgroundShells == .exceptServers)
        var old = AppSettings()
        old.revision = 3
        old.config.maxKeepAwake = 7200
        old.migrate()
        #expect(old.config.maxKeepAwake == 12 * 3600)
        // A setting saved before shells existed loads with the default policy.
        let decoded = try JSONDecoder().decode(Config.self, from: Data(#"{"graceSeconds":300}"#.utf8))
        #expect(decoded.backgroundShells == .exceptServers && decoded.graceSeconds == 300)
    }

    @Test func serverCommands() {
        for server in ["npm run dev", "pnpm dev", "yarn start", "next dev --turbo", "npx vite", "stripe listen --forward-to x",
                       "npx serve dist", "python3 -m http.server 8000", "docker compose up", "tail -f log.txt", "tail -F x"] {
            #expect(ServerCommands.isServer(server), "\(server)")
        }
        for work in ["npm test", "pnpm run build", "sleep 300", "pytest", "swift build", "tail -n 20 log", "git push"] {
            #expect(!ServerCommands.isServer(work), "\(work)")
        }
    }
}

private extension Event {
    func withNotificationType(_ type: String) -> Event {
        guard case .hook(var h) = self else { return self }
        h.notificationType = type
        return .hook(h)
    }
}
