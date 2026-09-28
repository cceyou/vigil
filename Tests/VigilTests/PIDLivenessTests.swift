import Foundation
import Testing
@testable import VigilCore

@Suite struct PIDLivenessTests {
    private func session(_ id: String, pid: Int32?) -> Session {
        Session(id: id, cwd: nil, pid: pid, state: .working, startedAt: t0, lastEventAt: t0, stateSince: t0)
    }

    @Test func injectedLivenessSelectsDeadSessions() {
        let sessions = [session("alive", pid: 10), session("dead", pid: 20), session("nopid", pid: nil)]
        let dead = PIDLiveness.deadSessions(in: sessions, isAlive: { $0 == 10 })
        #expect(dead == ["dead"]) // sessions without a PID are never pruned
    }

    @Test func realProcessIsAliveThenDead() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let pid = child.processIdentifier
        let s = [session("x", pid: pid)]
        #expect(PIDLiveness.deadSessions(in: s).isEmpty)

        child.terminate()
        child.waitUntilExit()
        #expect(PIDLiveness.deadSessions(in: s) == ["x"])
    }

    @Test func prunedSessionFlowsThroughTheMachine() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit, "x", pid: child.processIdentifier), at: at(0))
        child.terminate(); child.waitUntilExit()

        let dead = PIDLiveness.deadSessions(in: m.sessions)
        let fx = m.handle(.sessionsDied(dead), at: at(10))
        #expect(fx.contains(.showCountdown(deadline: at(40))))
        #expect(m.sessions.isEmpty)
    }
}
