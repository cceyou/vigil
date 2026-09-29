import Foundation
import Testing
@testable import VigilCore

func subagent(_ kind: HookKind, _ agent: String, type: String? = "Explore", session: String = "a", pid: Int32? = nil) -> Event {
    .hook(HookEvent(kind: kind, sessionID: session, cwd: "/Users/me/proj", pid: pid, agentID: agent, agentType: type))
}

@Suite struct SubagentTests {
    @Test func stopWithActiveSubagentsDoesNotSleep() {
        var m = machine { $0.graceSeconds = 30 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(5))
        // The main agent ends its turn while the subagent keeps working: no countdown.
        #expect(m.handle(hook(.stop), at: at(10)).isEmpty)
        #expect(m.phase == .working)
        #expect(m.sessions[0].state == .idle)
        #expect(m.sessions[0].isWorking)
        #expect(m.sessions[0].onlySubagentsWorking)
        #expect(m.countdownDeadline == nil)
        // Long after the grace period it still has not slept.
        #expect(m.handle(.tick, at: at(3600)).isEmpty)
        #expect(m.awakeHeld)
    }

    @Test func lastSubagentStopStartsTheGracePeriod() {
        var m = machine { $0.graceSeconds = 30 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(1))
        _ = m.handle(subagent(.subagentStart, "x2", type: "code-reviewer"), at: at(2))
        _ = m.handle(hook(.stop), at: at(10))
        #expect(m.handle(subagent(.subagentStop, "x1"), at: at(100)).isEmpty) // one still running
        #expect(m.phase == .working)
        #expect(m.handle(subagent(.subagentStop, "x2"), at: at(200)) == [.showCountdown(deadline: at(230))])
        #expect(m.phase == .countdown)
        #expect(m.handle(.tick, at: at(230)) == [.dismissCountdown, .releaseAwake, .sleepNow])
    }

    @Test func subagentStartDuringCountdownCancelsIt() {
        var m = machine { $0.graceSeconds = 30 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(10))
        #expect(m.phase == .countdown)
        #expect(m.handle(subagent(.subagentStart, "bg"), at: at(20)) == [.dismissCountdown])
        #expect(m.phase == .working)
        #expect(m.handle(.tick, at: at(500)).isEmpty) // the old deadline no longer fires
        #expect(m.handle(subagent(.subagentStop, "bg"), at: at(600)) == [.showCountdown(deadline: at(630))])
    }

    @Test func unknownSubagentStopIsIgnored() {
        var m = machine()
        // Unknown session (Vigil started mid-session): nothing is created.
        #expect(m.handle(subagent(.subagentStop, "ghost", session: "never-seen"), at: at(0)).isEmpty)
        #expect(m.sessions.isEmpty)
        // Known session, unknown agent: the tracked one is untouched.
        _ = m.handle(hook(.userPromptSubmit), at: at(1))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(2))
        let before = m
        #expect(m.handle(subagent(.subagentStop, "ghost"), at: at(3)).isEmpty)
        #expect(m == before)
        #expect(m.sessions[0].subagents.map(\.id) == ["x1"])
    }

    @Test func subagentStartWithoutAgentIDIsNotTracked() {
        var m = machine()
        #expect(m.handle(.hook(HookEvent(kind: .subagentStart, sessionID: "a")), at: at(0)).isEmpty)
        #expect(m.sessions.isEmpty)
    }

    @Test func duplicateSubagentStartKeepsOneEntry() {
        var m = machine()
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(0))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(5))
        #expect(m.sessions[0].subagents.count == 1)
        #expect(m.sessions[0].subagents[0].startedAt == at(0))
    }

    @Test func subagentStartAdoptsAnUnknownSession() {
        var m = machine()
        #expect(m.handle(subagent(.subagentStart, "x1", pid: 77), at: at(0)) == [.acquireAwake])
        #expect(m.sessions.first?.state == .idle)
        #expect(m.sessions.first?.pid == 77)
        #expect(m.phase == .working)
    }

    @Test func stuckSubagentIsDroppedAfterTheLimit() {
        var m = machine { $0.stuckSubagentLimit = 7200; $0.graceSeconds = 30 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(subagent(.subagentStart, "lost", type: "general-purpose"), at: at(10))
        _ = m.handle(hook(.stop), at: at(20))
        #expect(m.handle(.tick, at: at(10 + 7200)).isEmpty) // exactly at the limit: kept
        let fx = m.handle(.tick, at: at(10 + 7201))
        #expect(fx == [.droppedStuckSubagent(project: "proj", agentID: "lost", agentType: "general-purpose", age: 7201),
                       .showCountdown(deadline: at(10 + 7201 + 30))])
        #expect(m.sessions[0].subagents.isEmpty)
        #expect(m.phase == .countdown)
    }

    @Test func stuckLimitFollowsConfig() {
        var m = machine { $0.stuckSubagentLimit = 1800 }
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(0))
        var config = m.config
        config.stuckSubagentLimit = 4 * 3600
        _ = m.handle(.configChanged(config), at: at(1))
        #expect(m.handle(.tick, at: at(3600)).isEmpty)
        #expect(m.sessions[0].subagents.count == 1)
    }

    @Test func multipleSessionsOnlyOneWithSubagents() {
        var m = machine { $0.graceSeconds = 30 }
        _ = m.handle(hook(.userPromptSubmit, "a"), at: at(0))
        _ = m.handle(hook(.userPromptSubmit, "b"), at: at(1))
        _ = m.handle(subagent(.subagentStart, "x1", session: "b"), at: at(2))
        _ = m.handle(hook(.stop, "a"), at: at(10))
        _ = m.handle(hook(.stop, "b"), at: at(11))
        // a is idle; b's main agent is idle but its subagent still runs.
        #expect(m.phase == .working)
        #expect(m.workingSessions.map(\.id) == ["b"])
        #expect(m.sessions.first { $0.id == "a" }?.subagents.isEmpty == true)
        // A subagent stop sent with the wrong session does not end b's subagent.
        #expect(m.handle(subagent(.subagentStop, "x1", session: "a"), at: at(20)).isEmpty)
        #expect(m.phase == .working)
        #expect(m.handle(subagent(.subagentStop, "x1", session: "b"), at: at(30)) == [.showCountdown(deadline: at(60))])
    }

    @Test func sessionEndClearsSubagentsAndRecordsThem() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(10))
        _ = m.handle(subagent(.subagentStart, "x2"), at: at(20))
        _ = m.handle(subagent(.subagentStop, "x1"), at: at(70))   // 60 s
        _ = m.handle(subagent(.subagentStart, "x3"), at: at(80))
        let fx = m.handle(hook(.sessionEnd), at: at(100))       // x2: 80 s, x3: 20 s still running
        guard case .record(let r) = fx.first else { Issue.record("expected a record"); return }
        #expect(r.maxSubagents == 2)
        #expect(r.subagentTime == 160)
        #expect(m.sessions.isEmpty)
        #expect(fx.contains(.showCountdown(deadline: at(130))))
    }

    @Test func deadProcessClearsSubagents() {
        var m = machine()
        _ = m.handle(subagent(.subagentStart, "x1", pid: 4242), at: at(0))
        let fx = m.handle(.sessionsDied(["a"]), at: at(30))
        guard case .record(let r) = fx.first else { Issue.record("expected a record"); return }
        #expect(r.reason == .interrupted)
        #expect(r.maxSubagents == 1)
        #expect(m.sessions.isEmpty)
        #expect(fx.contains(.showCountdown(deadline: at(60))))
    }

    @Test func subagentsKeepWaitingSessionAwakeUnderIdlePolicy() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(1))
        #expect(m.handle(hook(.notification), at: at(5)).isEmpty) // waiting would count as idle, but a subagent works
        #expect(m.phase == .working)
    }

    @Test func workingSinceUsesEarliestSubagentOnceMainIsIdle() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(subagent(.subagentStart, "x1"), at: at(30))
        _ = m.handle(subagent(.subagentStart, "x2"), at: at(40))
        #expect(m.sessions[0].workingSince == at(0))
        _ = m.handle(hook(.stop), at: at(50))
        #expect(m.sessions[0].workingSince == at(30))
        #expect(m.sessions[0].subagentTime(at: at(100)) == 130)
    }

    // MARK: persistence

    @Test func oldHistoryWithoutSubagentFieldsStillLoads() throws {
        let old = #"[{"id":"1","project":"p","startedAt":"2026-01-01T10:00:00Z","duration":60,"reason":"ended"}]"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let list = try d.decode([SessionRecord].self, from: Data(old.utf8))
        #expect(list.first?.maxSubagents == 0)
        #expect(list.first?.subagentTime == 0)
    }

    @Test func settingsFromBeforeStuckLimitKeepTheirValues() throws {
        let old = #"{"graceSeconds":120,"maxKeepAwake":3600,"lowBatteryThreshold":10,"sleepOnlyIfLidClosed":true,"notificationPolicy":"keepAwake","manualKeepAwake":3600}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(c.graceSeconds == 120)
        #expect(c.notificationPolicy == .keepAwake)
        #expect(c.stuckSubagentLimit == 2 * 3600)
    }

    // MARK: parser

    @Test func parserReadsAgentFields() {
        let line = #"{"vigil_event":"SubagentStart","pid":99,"payload":{"session_id":"s1","cwd":"/a","hook_event_name":"SubagentStart","agent_id":"ag-1","agent_type":"Explore"}}"#
        #expect(HookEventParser.parse(Data(line.utf8)) ==
                HookEvent(kind: .subagentStart, sessionID: "s1", cwd: "/a", pid: 99, agentID: "ag-1", agentType: "Explore"))
        let stop = #"{"session_id":"s1","hook_event_name":"SubagentStop","agent_id":"ag-1"}"#
        #expect(HookEventParser.parse(Data(stop.utf8))?.kind == .subagentStop)
        #expect(HookEventParser.parse(Data(stop.utf8))?.agentType == nil)
    }

    // MARK: self-test sandbox

    @Test func selfTestProbeRunsSubagentEventsInASandbox() {
        let probe = SelfTestProbe()
        let id = "\(SelfTest.sessionPrefix)x"
        probe.received(HookEvent(kind: .subagentStart, sessionID: id, agentID: "g", agentType: "vigil-selftest"))
        probe.received(HookEvent(kind: .subagentStop, sessionID: id, agentID: "g"))
        #expect(probe.trace(for: id) == [true, false])
        #expect(SelfTest.isSelfTestEvent(HookEvent(kind: .subagentStart, sessionID: id)))
        #expect(!SelfTest.isSelfTestEvent(HookEvent(kind: .subagentStart, sessionID: "real-session")))
        // Real sessions never touch the sandbox.
        probe.received(HookEvent(kind: .subagentStart, sessionID: "real-session", agentID: "g"))
        #expect(probe.trace(for: "real-session").isEmpty)
    }
}
