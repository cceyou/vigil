import Foundation
import Testing
@testable import VigilCore

private func snap(lid closed: Bool, displays: Int = 0, idle: TimeInterval, assertions: [PowerAssertion] = [],
                  own: Int32 = 500) -> PresenceSnapshot {
    PresenceSnapshot(lidClosed: closed, externalDisplays: displays, idleSeconds: idle, assertions: assertions, ownPID: own)
}

private let zoom = PowerAssertion(pid: 900, process: "zoom.us", type: "PreventUserIdleDisplaySleep", name: "Zoom meeting")
private let claudeCaffeinate = PowerAssertion(pid: 901, process: "caffeinate", type: "PreventUserIdleSystemSleep",
                                              name: "caffeinate command-line tool", parentProcess: "claude")
private let userCaffeinate = PowerAssertion(pid: 902, process: "caffeinate", type: "PreventUserIdleSystemSleep",
                                            name: "caffeinate command-line tool", parentProcess: "zsh")
private let powerd = PowerAssertion(pid: 335, process: "powerd", type: "PreventUserIdleSystemSleep",
                                    name: "Powerd - Prevent sleep while display is on")
private let vigil = PowerAssertion(pid: 500, process: "Vigil", type: "PreventUserIdleSystemSleep", name: "Vigil: Claude Code is working")

// MARK: - The gate (pure)

@Suite struct SleepGateTests {
    @Test func lidClosedNoDisplaySleeps() {
        let d = SleepGate.decide(snap(lid: true, idle: 0), lidOpenIdleThreshold: 0)
        #expect(d == GateDecision(allow: true, reason: .lidClosedNoDisplay))
        // Nobody can be using it, so even another app's assertion does not stop it.
        #expect(SleepGate.decide(snap(lid: true, idle: 0, assertions: [zoom]), lidOpenIdleThreshold: 0).allow)
    }

    @Test func lidOpenActiveSkips() {
        let d = SleepGate.decide(snap(lid: false, idle: 12), lidOpenIdleThreshold: 0)
        #expect(d == GateDecision(allow: false, reason: .lidOpen(idleSeconds: 12)))
        #expect(!SleepGate.decide(snap(lid: false, idle: 12), lidOpenIdleThreshold: 600).allow)
    }

    @Test func lidOpenIdlePastTheThresholdSleepsWhenTheSettingIsOn() {
        let d = SleepGate.decide(snap(lid: false, idle: 601), lidOpenIdleThreshold: 600)
        #expect(d == GateDecision(allow: true, reason: .idle(seconds: 601, threshold: 600)))
        let justBefore = SleepGate.decide(snap(lid: false, idle: 599), lidOpenIdleThreshold: 600)
        #expect(justBefore == GateDecision(allow: false, reason: .recentInput(seconds: 599, threshold: 600)))
    }

    @Test func lidOpenIdleButSettingOffSkips() {
        let d = SleepGate.decide(snap(lid: false, idle: 7200), lidOpenIdleThreshold: 0)
        #expect(!d.allow)
        #expect(d.reason == .lidOpen(idleSeconds: 7200))
    }

    @Test func clamshellWithExternalDisplayAndActiveInputSkips() {
        let d = SleepGate.decide(snap(lid: true, displays: 1, idle: 3), lidOpenIdleThreshold: 0)
        #expect(d == GateDecision(allow: false, reason: .externalDisplay(idleSeconds: 3)))
        #expect(!SleepGate.decide(snap(lid: true, displays: 2, idle: 3), lidOpenIdleThreshold: 300).allow)
        // Desktop mode but away long enough, with the setting on: allowed.
        #expect(SleepGate.decide(snap(lid: true, displays: 1, idle: 400), lidOpenIdleThreshold: 300).allow)
    }

    @Test func foreignAssertionSkips() {
        let d = SleepGate.decide(snap(lid: false, idle: 9999, assertions: [zoom]), lidOpenIdleThreshold: 300)
        #expect(d == GateDecision(allow: false, reason: .assertion(process: "zoom.us")))
        #expect(SleepGate.decide(snap(lid: false, idle: 9999, assertions: [userCaffeinate]), lidOpenIdleThreshold: 300).reason
                == .assertion(process: "caffeinate"))
        // Only idle-sleep assertions count.
        let background = PowerAssertion(pid: 687, process: "nsurlsessiond", type: "SystemIsActive", name: "NSURLSessionTask")
        #expect(SleepGate.decide(snap(lid: false, idle: 9999, assertions: [background]), lidOpenIdleThreshold: 300).allow)
    }

    @Test func claudesOwnCaffeinateVigilAndPowerdAreIgnored() {
        let s = snap(lid: false, idle: 9999, assertions: [claudeCaffeinate, powerd, vigil])
        #expect(SleepGate.foreignAssertions(s).isEmpty)
        #expect(SleepGate.decide(s, lidOpenIdleThreshold: 300).allow)
        #expect(SleepGate.foreignAssertions(snap(lid: false, idle: 1, assertions: [claudeCaffeinate, userCaffeinate])) == [userCaffeinate])
    }

    @Test func claudeCodeIsRecognisedByItsVersionedBinary() {
        // What this machine really reports for the caffeinate's parent: name "2.1.284", path in versions/.
        #expect(SleepGate.isClaudeCode(executablePath: "/Users/me/.local/share/claude/versions/2.1.284", processName: "2.1.284"))
        #expect(SleepGate.isClaudeCode(executablePath: "/opt/homebrew/bin/claude", processName: "claude"))
        #expect(SleepGate.isClaudeCode(executablePath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", processName: "node"))
        #expect(!SleepGate.isClaudeCode(executablePath: "/bin/zsh", processName: "zsh"))
        #expect(!SleepGate.isClaudeCode(executablePath: "/Applications/Claude.app/Contents/MacOS/Claude", processName: "Claude"))
        #expect(!SleepGate.isClaudeCode(executablePath: nil, processName: nil))
    }

    @Test func noReadingNeverSleeps() {
        #expect(SleepGate.decide(nil, lidOpenIdleThreshold: 300) == GateDecision(allow: false, reason: .unknown))
    }

    @Test func logLines() {
        #expect(SleepDecisionRecord(date: t0, trigger: .countdownExpired, slept: true, reason: .lidClosedNoDisplay).logLine
                == "sleep: lid closed, no external display [countdownExpired]")
        #expect(SleepDecisionRecord(date: t0, trigger: .finished, slept: false, reason: .lidOpen(idleSeconds: 12)).logLine
                == "skip: lid open, user active 12 s ago (sleep with lid open: never) [finished]")
        #expect(GateReason.assertion(process: "Zoom").logText == "assertion held by Zoom")
    }
}

// MARK: - The gate inside the state machine

@Suite struct SleepGateMachineTests {
    @Test func atTheMacClaudeFinishingHandsSleepBackWithoutACountdown() throws {
        var m = machine(presence: atTheMac)
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        let fx = m.handle(hook(.stop), at: at(60))
        #expect(fx.power == [.releaseAwake]) // no showCountdown, so no notification either
        #expect(fx.decisions == [SleepDecisionRecord(date: at(60), trigger: .finished, slept: false, reason: .lidOpen(idleSeconds: 2))])
        #expect(m.phase == .armed)
        #expect(!m.awakeHeld)
        #expect(m.handedBack?.trigger == .finished)
        // Later ticks never sleep.
        #expect(m.handle(.tick, at: at(4000)).isEmpty)
        // The next working turn clears "Hotovo · Mac běží normálně".
        _ = m.handle(hook(.userPromptSubmit), at: at(5000))
        #expect(m.handedBack == nil)
    }

    @Test func awayTheCountdownRunsAndSleeps() {
        var m = machine(presence: .away)
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(hook(.stop), at: at(60)) == [.showCountdown(deadline: at(90))])
        _ = m.handle(.presence(.away), at: at(70))
        let fx = m.handle(.tick, at: at(90))
        #expect(fx.power == [.dismissCountdown, .releaseAwake, .sleepNow])
        #expect(fx.decisions.first?.slept == true)
        #expect(fx.decisions.first?.reason == .lidClosedNoDisplay)
    }

    @Test func inputCancelsTheCountdown() {
        // Lid open, the setting says 5 min, the user was away 10 min: the countdown starts.
        var away10 = atTheMac
        away10.idleSeconds = 600
        var m = machine(presence: away10) { $0.lidOpenIdleSleep = 300 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(hook(.stop), at: at(60)) == [.showCountdown(deadline: at(90))])
        away10.idleSeconds = 610
        #expect(m.handle(.presence(away10), at: at(70)).isEmpty) // still away: keeps counting
        // A key press: idle drops to 1 s although the countdown has run 15 s.
        var back = away10
        back.idleSeconds = 1
        let fx = m.handle(.presence(back), at: at(75))
        #expect(fx.power == [.dismissCountdown, .releaseAwake])
        #expect(fx.decisions == [SleepDecisionRecord(date: at(75), trigger: .countdownCancelled, slept: false,
                                                     reason: .inputDuringCountdown(seconds: 1))])
        #expect(m.phase == .armed)
        #expect(m.countdownDeadline == nil)
        #expect(m.handedBack == nil) // back to "Připraveno"
        #expect(m.handle(.tick, at: at(90)).isEmpty) // no sleep at the old deadline
    }

    @Test func openingTheLidCancelsTheCountdown() {
        var m = machine(presence: .away)
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(60))
        // Lid opened; the trackpad has not been touched yet (idle still long).
        let opened = PresenceSnapshot(lidClosed: false, externalDisplays: 0, idleSeconds: 3600)
        let fx = m.handle(.presence(opened), at: at(65))
        #expect(fx.power == [.dismissCountdown, .releaseAwake])
        #expect(fx.decisions.first?.reason == .lidOpen(idleSeconds: 3600))
        #expect(m.phase == .armed)
    }

    @Test func sleepNowAlwaysSleeps() {
        for presence in [atTheMac, .away, PresenceSnapshot(lidClosed: false, externalDisplays: 1, idleSeconds: 0, assertions: [zoom])] {
            var m = machine(presence: presence)
            _ = m.handle(hook(.userPromptSubmit), at: at(0))
            let fx = m.handle(.sleepNow, at: at(5))
            #expect(fx.power == [.releaseAwake, .sleepNow])
            #expect(fx.decisions.first?.reason == .userRequested)
        }
        var noReading = machine(presence: nil)
        #expect(noReading.handle(.sleepNow, at: at(0)).power == [.sleepNow])
    }

    @Test func maxDurationFailsafeUsesTheGate() {
        var m = machine(presence: atTheMac) { $0.maxKeepAwake = 100 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.postToolUse), at: at(90))
        let fx = m.handle(.tick, at: at(100))
        #expect(fx.power == [.notifyGuard(.maxDuration), .releaseAwake]) // released, not slept: someone is here
        #expect(fx.decisions.first?.trigger == .maxDuration)
        #expect(!m.awakeHeld)
    }

    @Test func batteryGuardInDesktopModeDoesNotForceSleep() {
        let desktop = PresenceSnapshot(lidClosed: true, externalDisplays: 1, idleSeconds: 1)
        var m = machine(presence: desktop) { $0.lowBatteryThreshold = 15 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        let fx = m.handle(.environment(Environment(lidClosed: true, onBattery: true, batteryPercent: 10)), at: at(1))
        #expect(fx.power == [.notifyGuard(.lowBattery), .releaseAwake])
        #expect(fx.decisions.first == SleepDecisionRecord(date: at(1), trigger: .lowBattery, slept: false,
                                                          reason: .externalDisplay(idleSeconds: 1)))
    }

    @Test func withoutAnyPresenceReadingNothingIsForced() {
        var m = machine(presence: nil)
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        let fx = m.handle(hook(.stop), at: at(10))
        #expect(fx.power == [.releaseAwake])
        #expect(fx.decisions.first?.reason == .unknown)
    }

    @Test func keepAwakeExpiryWithSomeoneAtTheMacDoesNotSleep() {
        // Today's second incident: "+1 h" ran out while the lid was open.
        var m = machine(presence: atTheMac) { $0.graceSeconds = 300 }
        _ = m.handle(.keepAwake(.minutes(60)), at: at(0))
        #expect(m.awakeHeld)
        let fx = m.handle(.tick, at: at(3600))
        #expect(!fx.power.contains(.sleepNow))
        #expect(!fx.power.contains { if case .showCountdown = $0 { return true } else { return false } })
        #expect(!m.awakeHeld)
    }

    @Test func decisionsAreStored() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SleepDecisionStore(url: dir.appendingPathComponent("d.json"))
        let a = SleepDecisionRecord(date: t0, trigger: .finished, slept: false, reason: .assertion(process: "zoom.us"))
        let b = SleepDecisionRecord(date: at(5), trigger: .countdownExpired, slept: true, reason: .idle(seconds: 700, threshold: 600))
        store.append(a)
        #expect(store.append(b) == [b, a])
        #expect(store.load() == [b, a])
    }

    @Test func selfTestReportsWhatTheGateWouldDecide() {
        let test = SelfTest(probe: SelfTestProbe(), isNotificationAuthorized: { true }, awakeHeld: false, lidOpenIdleSleep: 0,
                            readPresence: { PresenceSnapshot(lidClosed: false, externalDisplays: 1, idleSeconds: 4, assertions: [zoom]) })
        let r = test.checkSleepGate()
        #expect(r.id == .sleepGate)
        #expect(r.passed)
        #expect(r.detail.contains("zoom.us"))
        #expect(r.detail.contains("4 s"))
        #expect(r.detail.contains("would not force sleep"))
    }
}
