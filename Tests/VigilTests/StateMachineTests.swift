import Foundation
import Testing
@testable import VigilCore

@Suite struct StateMachineTests {
    @Test func armedUntilClaudeWorks() {
        var m = machine()
        #expect(m.phase == .armed)
        #expect(m.handle(hook(.sessionStart), at: at(0)).isEmpty)
        #expect(m.phase == .armed)
        #expect(!m.awakeHeld)
    }

    @Test func promptAcquiresAwakeOnce() {
        var m = machine()
        #expect(m.handle(hook(.userPromptSubmit), at: at(0)) == [.acquireAwake])
        #expect(m.phase == .working)
        #expect(m.awakeHeld)
        // A second prompt does not re-acquire.
        #expect(m.handle(hook(.userPromptSubmit), at: at(5)).isEmpty)
    }

    @Test func stopStartsCountdownThenRestoresBeforeSleeping() {
        var m = machine { $0.graceSeconds = 30 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(hook(.stop), at: at(10)) == [.showCountdown(deadline: at(40))])
        #expect(m.phase == .countdown)
        #expect(m.handle(.tick, at: at(39)).isEmpty)
        let fx = m.handle(.tick, at: at(40))
        #expect(fx == [.dismissCountdown, .releaseAwake, .sleepNow])
        #expect(m.phase == .armed)
        #expect(!m.awakeHeld)
    }

    @Test func restoreAlwaysPrecedesSleep() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(1))
        let fx = m.handle(.tick, at: at(100))
        let release = fx.firstIndex(of: .releaseAwake)
        let sleep = fx.firstIndex(of: .sleepNow)
        #expect(release != nil && sleep != nil && release! < sleep!)
    }

    @Test func multipleSessionsSleepOnlyWhenAllIdle() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit, "a"), at: at(0))
        _ = m.handle(hook(.userPromptSubmit, "b"), at: at(1))
        #expect(m.handle(hook(.stop, "a"), at: at(10)).isEmpty)
        #expect(m.phase == .working)
        #expect(m.handle(hook(.stop, "b"), at: at(20)) == [.showCountdown(deadline: at(50))])
        #expect(m.phase == .countdown)
    }

    @Test func newPromptDuringCountdownCancelsIt() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(10))
        let fx = m.handle(hook(.userPromptSubmit), at: at(20))
        #expect(fx == [.dismissCountdown])
        #expect(m.phase == .working)
        #expect(m.awakeHeld)
        #expect(m.handle(.tick, at: at(500)).isEmpty)
    }

    @Test func subagentFollowUpWithinGraceKeepsMacAwake() {
        var m = machine { $0.graceSeconds = 30 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(10))
        _ = m.handle(hook(.userPromptSubmit), at: at(35)) // arrives inside the grace window
        #expect(m.handle(.tick, at: at(45)).isEmpty)
        #expect(m.phase == .working)
    }

    @Test func cancelReturnsToArmedWithoutSleeping() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(10))
        let fx = m.handle(.cancelCountdown, at: at(15))
        #expect(fx == [.dismissCountdown, .releaseAwake])
        #expect(!fx.contains(.sleepNow))
        #expect(m.phase == .armed)
        #expect(m.handle(.tick, at: at(500)).isEmpty)
    }

    @Test func keepAwakeButtonHoldsForAnHour() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.stop), at: at(10))
        #expect(m.handle(.keepAwake, at: at(15)) == [.dismissCountdown])
        #expect(m.phase == .working)
        #expect(m.handle(.tick, at: at(3000)).isEmpty)
        // After the hour it becomes idle again: countdown, then sleep.
        #expect(m.handle(.tick, at: at(15 + 3600 + 1)) == [.showCountdown(deadline: at(15 + 3600 + 1 + 30))])
        #expect(m.handle(.tick, at: at(15 + 3600 + 31)).contains(.sleepNow))
    }

    @Test func keepAwakeFromArmedAcquires() {
        var m = machine()
        #expect(m.handle(.keepAwake, at: at(0)) == [.acquireAwake])
        #expect(m.phase == .working)
    }

    // MARK: interrupted sessions

    @Test func deadProcessIsPrunedAndCountdownStarts() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit, "a", pid: 4242), at: at(0))
        let fx = m.handle(.sessionsDied(["a"]), at: at(30))
        #expect(fx.count == 2)
        guard case .record(let r) = fx[0] else { Issue.record("expected a history record"); return }
        #expect(r.reason == .interrupted)
        #expect(r.duration == 30)
        #expect(fx[1] == .showCountdown(deadline: at(60)))
        #expect(m.sessions.isEmpty)
    }

    @Test func workingSessionWithoutEventsIsDroppedAfterMaxDuration() {
        var m = machine { $0.maxKeepAwake = 100 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        let fx = m.handle(.tick, at: at(101))
        #expect(fx.contains { if case .record(let r) = $0 { return r.reason == .timedOut } else { return false } })
        #expect(m.sessions.isEmpty)
    }

    @Test func sessionEndRemovesAndRecords() {
        var m = machine()
        _ = m.handle(hook(.sessionStart), at: at(0))
        _ = m.handle(hook(.userPromptSubmit), at: at(1))
        let fx = m.handle(hook(.sessionEnd), at: at(61))
        guard case .record(let r) = fx.first else { Issue.record("expected a record"); return }
        #expect(r.reason == .ended)
        #expect(r.duration == 61)
        #expect(r.project == "proj")
        #expect(fx.contains(.showCountdown(deadline: at(91))))
    }

    // MARK: notification policy

    @Test func waitingKeepsMacAwakeByDefault() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(permissionPrompt(), at: at(5)).isEmpty)
        #expect(m.sessions[0].state == .waiting)
        #expect(m.phase == .working)
    }

    @Test func waitingCountsAsIdleUnderSleepAfterDelay() {
        var m = machine { $0.notificationPolicy = .treatAsIdle }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(permissionPrompt(), at: at(5)) == [.showCountdown(deadline: at(35))])
        #expect(m.sessions[0].state == .waiting)
    }

    @Test func toolHeartbeatResumesWorkingAfterApprovedPermissionPrompt() {
        var m = machine { $0.notificationPolicy = .treatAsIdle }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(permissionPrompt(), at: at(5)) // sleep-after-delay policy: countdown
        #expect(m.handle(hook(.postToolUse), at: at(12)) == [.dismissCountdown])
        #expect(m.sessions[0].state == .working)
        #expect(m.phase == .working)
    }

    @Test func toolHeartbeatNeverRevivesAnIdleSession() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(1))
        _ = m.handle(hook(.stop), at: at(2))
        _ = m.handle(hook(.postToolUse), at: at(3)) // late/out-of-order: must not pin the Mac awake
        #expect(m.sessions[0].state == .idle)
    }

    @Test func toolHeartbeatWithoutPidFromUnknownSessionIsIgnored() {
        var m = machine()
        #expect(m.handle(hook(.postToolUse, "ghost", pid: nil), at: at(0)).isEmpty)
        #expect(m.sessions.isEmpty)
    }

    @Test func toolHeartbeatAdoptsAnUnknownSessionAfterAppRestart() {
        var m = machine()
        // Vigil was restarted while Claude was mid-task: the first thing it hears is a tool heartbeat.
        #expect(m.handle(hook(.postToolUse, "restarted", pid: 555), at: at(0)) == [.acquireAwake])
        #expect(m.sessions.first?.state == .working)
        #expect(m.sessions.first?.pid == 555)
        // A dead process is still pruned, so an adopted session can never pin the Mac forever.
        let fx = m.handle(.sessionsDied(["restarted"]), at: at(5))
        #expect(fx.contains(.showCountdown(deadline: at(35))))
    }

    // MARK: guards

    @Test func maxKeepAwakeRestoresAndSleeps() {
        var m = machine { $0.maxKeepAwake = 100 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(hook(.postToolUse), at: at(90)) // heartbeat keeps the session from being dropped as stale
        let fx = m.handle(.tick, at: at(100))
        #expect(fx == [.notifyGuard(.maxDuration), .releaseAwake, .sleepNow])
        #expect(!m.awakeHeld)
        // Still "working" but latched: must not re-acquire.
        #expect(m.handle(hook(.postToolUse), at: at(101)).isEmpty)
        #expect(m.phase == .armed)
        // Once idle the latch clears and the next prompt works again.
        _ = m.handle(hook(.stop), at: at(200))
        #expect(m.latch == nil)
        #expect(m.handle(hook(.userPromptSubmit), at: at(300)) == [.acquireAwake])
    }

    @Test func lowBatteryOnBatteryTripsImmediately() {
        var m = machine { $0.lowBatteryThreshold = 15 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        let ok = m.handle(.environment(Environment(lidClosed: true, onBattery: true, batteryPercent: 15)), at: at(1))
        #expect(ok.isEmpty) // exactly at the threshold is not "below"
        let fx = m.handle(.environment(Environment(lidClosed: true, onBattery: true, batteryPercent: 14)), at: at(2))
        #expect(fx == [.notifyGuard(.lowBattery), .releaseAwake, .sleepNow])
        #expect(m.phase == .armed)
        // While still low, a new prompt does not re-acquire...
        #expect(m.handle(hook(.userPromptSubmit, "b"), at: at(3)).isEmpty)
        // ...but plugging in does.
        #expect(m.handle(.environment(Environment(onBattery: false, batteryPercent: 14)), at: at(4)) == [.acquireAwake])
    }

    @Test func lowBatteryWithLidOpenReleasesButDoesNotForceSleep() {
        var m = machine { $0.lowBatteryThreshold = 15 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        let fx = m.handle(.environment(Environment(lidClosed: false, onBattery: true, batteryPercent: 10)), at: at(1))
        #expect(fx == [.notifyGuard(.lowBattery), .releaseAwake])
        #expect(m.blockedReason == .lowBattery)
    }

    @Test func lowBatteryThresholdZeroDisablesGuard() {
        var m = machine { $0.lowBatteryThreshold = 0 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(.environment(Environment(lidClosed: true, onBattery: true, batteryPercent: 1)), at: at(1)).isEmpty)
        #expect(m.awakeHeld)
    }

    @Test func defaultThresholdIsFivePercent() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(.environment(Environment(lidClosed: true, onBattery: true, batteryPercent: 11)), at: at(1)).isEmpty)
        #expect(m.awakeHeld)
    }

    @Test func lowBatteryIgnoredOnAC() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(.environment(Environment(onBattery: false, batteryPercent: 3)), at: at(1)).isEmpty)
        #expect(m.awakeHeld)
    }

    @Test func thermalGuardOnlyWhenLidClosed() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(.environment(Environment(lidClosed: false, thermal: .critical)), at: at(1)).isEmpty)
        let fx = m.handle(.environment(Environment(lidClosed: true, thermal: .serious)), at: at(2))
        #expect(fx == [.notifyGuard(.thermal), .releaseAwake, .sleepNow])
        #expect(!m.awakeHeld)
    }

    @Test func thermalFairDoesNotTrip() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(.environment(Environment(lidClosed: true, thermal: .fair)), at: at(1)).isEmpty)
    }

    // MARK: lid option

    @Test func sleepOnlyIfLidClosedSkipsSleepWhenLidOpen() {
        var m = machine { $0.sleepOnlyIfLidClosed = true }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(.environment(Environment(lidClosed: false)), at: at(1))
        _ = m.handle(hook(.stop), at: at(2))
        let fx = m.handle(.tick, at: at(40))
        #expect(fx == [.dismissCountdown, .releaseAwake]) // restored, but no sleepnow
        #expect(m.phase == .armed)
    }

    @Test func sleepOnlyIfLidClosedSleepsWhenLidClosed() {
        var m = machine { $0.sleepOnlyIfLidClosed = true }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(.environment(Environment(lidClosed: true)), at: at(1))
        _ = m.handle(hook(.stop), at: at(2))
        #expect(m.handle(.tick, at: at(40)) == [.dismissCountdown, .releaseAwake, .sleepNow])
    }

    // MARK: master toggle and manual sleep

    @Test func disablingWhileWorkingRestoresWithoutSleeping() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        #expect(m.handle(.setEnabled(false), at: at(1)) == [.releaseAwake])
        #expect(m.phase == .off)
        #expect(m.handle(hook(.userPromptSubmit, "b"), at: at(2)).isEmpty) // does nothing to power while off
        #expect(m.handle(.setEnabled(true), at: at(3)) == [.acquireAwake])
    }

    @Test func disabledMachineNeverTouchesPower() {
        var m = machine(enabled: false)
        var all: [Effect] = []
        for e in [hook(.userPromptSubmit), hook(.stop), Event.tick] { all += m.handle(e, at: at(1)) }
        #expect(all.isEmpty)
        #expect(m.phase == .off)
    }

    @Test func sleepNowRestoresThenSleeps() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        let fx = m.handle(.sleepNow, at: at(1))
        #expect(fx == [.releaseAwake, .sleepNow])
        #expect(m.latch == .manualSleep)
        #expect(m.handle(hook(.postToolUse), at: at(2)).isEmpty) // no instant re-acquire
        #expect(m.handle(hook(.userPromptSubmit), at: at(3)) == [.acquireAwake]) // fresh prompt does
    }

    @Test func sleepNowWhileArmedJustSleeps() {
        var m = machine()
        #expect(m.handle(.sleepNow, at: at(0)) == [.sleepNow])
    }

    @Test func selfTestEventsNeverAffectState() {
        var m = machine()
        #expect(m.handle(hook(.selfTest, "vigil-selftest-1"), at: at(0)).isEmpty)
        #expect(m.sessions.isEmpty)
    }
}
