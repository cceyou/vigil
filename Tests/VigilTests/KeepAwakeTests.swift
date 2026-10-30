import Foundation
import Testing
@testable import VigilCore

/// "Nechat vzhůru": every duration of the split button, "Do odvolání", cancelling, and how it overrides the
/// max keep-awake failsafe while the battery and heat guards still apply.
@Suite struct KeepAwakeTests {
    @Test(arguments: [30, 60, 120, 240, 480, 95])
    func eachDurationHoldsExactlyThatLong(minutes: Int) {
        var m = machine { $0.graceSeconds = 30 }
        #expect(m.handle(.keepAwake(.minutes(minutes)), at: at(0)) == [.acquireAwake])
        let end = TimeInterval(minutes * 60)
        #expect(m.keepAwakeUntil == at(end))
        #expect(m.handle(.tick, at: at(end - 1)).isEmpty)
        #expect(m.phase == .working)
        // Then the normal grace period, and sleep.
        #expect(m.handle(.tick, at: at(end)) == [.showCountdown(deadline: at(end + 30))])
        #expect(m.handle(.tick, at: at(end + 30)).power == [.dismissCountdown, .releaseAwake, .sleepNow])
    }

    @Test func presetsAreTheMenu() {
        #expect(KeepAwakeDuration.presets == [.minutes(30), .minutes(60), .minutes(120), .minutes(240), .minutes(480), .untilCancelled])
        #expect(KeepAwakeDuration.minutes(90).seconds == 5400)
        #expect(KeepAwakeDuration.untilCancelled.seconds == nil)
    }

    @Test func untilCancelledHoldsPastTheTwelveHourLimit() {
        var m = machine { $0.graceSeconds = 30 }
        #expect(m.handle(.keepAwake(.untilCancelled), at: at(0)) == [.acquireAwake])
        #expect(m.keepAwakeIndefinite && m.keepAwakeUntil == nil)
        // 12 h is the absolute limit for Claude's work, but an explicit keep-awake overrides it.
        #expect(m.handle(.tick, at: at(12 * 3600)).isEmpty)
        #expect(m.handle(.tick, at: at(30 * 3600)).isEmpty)
        #expect(m.awakeHeld && m.phase == .working)
        // Cancelling hands back to the sessions: nothing works, so the grace period starts.
        #expect(m.handle(.cancelKeepAwake, at: at(30 * 3600 + 1)) == [.showCountdown(deadline: at(30 * 3600 + 31))])
        #expect(!m.keepAwakeIndefinite)
    }

    @Test func aTimedKeepAwakeAlsoOverridesTheLimitAndTheLimitAppliesAfterIt() {
        var m = machine { $0.maxKeepAwake = 3600 }
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(.keepAwake(.minutes(240)), at: at(1800))
        #expect(m.handle(.tick, at: at(3600)).isEmpty) // past the 1 h limit, inside the 4 h keep-awake
        let fx = m.handle(.tick, at: at(1800 + 4 * 3600))
        #expect(fx.contains(.notifyGuard(.maxDuration))) // the keep-awake ended; the limit applies again
    }

    @Test func cancelStopsATimedKeepAwakeWhileClaudeKeepsWorking() {
        var m = machine()
        _ = m.handle(hook(.userPromptSubmit), at: at(0))
        _ = m.handle(.keepAwake(.minutes(60)), at: at(10))
        #expect(m.handle(.cancelKeepAwake, at: at(20)).isEmpty) // Claude still works: stays awake
        #expect(m.keepAwakeUntil == nil && m.phase == .working)
    }

    @Test func batteryAndHeatGuardsStillApplyWithTheLidClosed() {
        var low = machine()
        _ = low.handle(.keepAwake(.untilCancelled), at: at(0))
        let fx = low.handle(.environment(Environment(lidClosed: true, onBattery: true, batteryPercent: 3)), at: at(10))
        #expect(fx.contains(.notifyGuard(.lowBattery)) && fx.contains(.releaseAwake))
        #expect(!low.keepAwakeIndefinite && !low.awakeHeld)

        var hot = machine()
        _ = hot.handle(.keepAwake(.minutes(480)), at: at(0))
        let heat = hot.handle(.environment(Environment(lidClosed: true, thermal: .critical)), at: at(10))
        #expect(heat.contains(.notifyGuard(.thermal)) && !hot.awakeHeld)
    }

    @Test func aNewChoiceReplacesTheRunningOne() {
        var m = machine()
        _ = m.handle(.keepAwake(.untilCancelled), at: at(0))
        _ = m.handle(.keepAwake(.minutes(30)), at: at(100))
        #expect(!m.keepAwakeIndefinite && m.keepAwakeUntil == at(1900))
        #expect(m.keepAwakeStartedAt == at(100))
    }

    @Test func theLastDurationIsRememberedAndOldSettingsLoad() throws {
        var ui = UISettings()
        #expect(ui.lastKeepAwake == .minutes(60))
        for d in KeepAwakeDuration.presets + [.minutes(135)] {
            ui.lastKeepAwake = d
            let back = try JSONDecoder().decode(UISettings.self, from: JSONEncoder().encode(ui))
            #expect(back.lastKeepAwake == d)
        }
        let old = try JSONDecoder().decode(UISettings.self, from: Data(#"{"notchEnabled":true}"#.utf8))
        #expect(old.lastKeepAwake == .minutes(60))
    }
}
