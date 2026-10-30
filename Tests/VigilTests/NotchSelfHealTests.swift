import Foundation
import Testing
@testable import VigilCore

/// The self-healing of the edge notch: the 30 s health check, the rebuild from scratch and the watchdog reading
/// the window server's on-screen flag.
@Suite struct NotchSelfHealTests {
    private let ok = NotchHealth.Panel(onScreen: true, trackingInstalled: true)

    @Test func healthyPanelsReportNothing() {
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: false, notches: [1: ok], card: nil, wantedDisplays: [1])).isEmpty)
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: true, notches: [1: ok], card: ok, wantedDisplays: [1])).isEmpty)
        // A closed card is ordered out; a hidden notch (full screen) is not on screen either. Both fine.
        let off = NotchHealth.Panel(onScreen: false, trackingInstalled: true)
        #expect(NotchHealth.problems(.init(notchShown: false, cardShown: false, notches: [1: off], card: off, wantedDisplays: [1])).isEmpty)
    }

    /// 30 Oct 2026: the state machine opened the card, the window server never showed it.
    @Test func theCardOfThirtyOctoberIsCaught() {
        let dead = NotchHealth.Panel(onScreen: false, trackingInstalled: true)
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: true, notches: [1: ok], card: dead, wantedDisplays: [1]))
                == ["card open but not on screen"])
        // While it slides out, nothing is wrong yet.
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: false, cardClosing: true, notches: [1: ok], card: ok,
                                           wantedDisplays: [1])).isEmpty)
    }

    @Test func lostTrackingAreasOffScreenNotchesAndDisplayChangesAreCaught() {
        let noTracking = NotchHealth.Panel(onScreen: true, trackingInstalled: false)
        let offScreen = NotchHealth.Panel(onScreen: false, trackingInstalled: true)
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: false, notches: [1: noTracking], card: nil, wantedDisplays: [1]))
                == ["notch on display 1 lost its tracking area"])
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: false, notches: [1: offScreen], card: nil, wantedDisplays: [1]))
                == ["notch on display 1 not on screen"])
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: true, notches: [1: ok], card: noTracking, wantedDisplays: [1]))
                == ["card lost its tracking area"])
        #expect(NotchHealth.problems(.init(notchShown: false, cardShown: false, notches: [1: ok], card: ok, wantedDisplays: [1]))
                == ["card on screen but closed"])
        // A display was connected (or its ID changed after sleep) and has no notch yet.
        #expect(NotchHealth.problems(.init(notchShown: true, cardShown: false, notches: [1: ok], card: nil, wantedDisplays: [1, 2]))
                == ["notches for displays [1] but displays [1, 2]"])
    }

    @Test func rebuildStartsOverFromHiddenAndTheNextVisibilityShows() {
        var m = NotchMachine()
        _ = m.handle(.visibility(allowed: true))
        _ = m.handle(.shortcut) // pinned, outside-click monitor on
        #expect(m.phase == .pinned)
        let fx = m.handle(.rebuilt)
        #expect(fx.contains(.cancelTimers) && fx.contains(.watchOutsideClicks(false)))
        #expect(m.phase == .hidden && !m.notchShown && !m.cardShown)
        // A timer from before the rebuild does nothing.
        let stale = m.token - 1
        #expect(m.handle(.timer(.hideDelay, token: stale)).isEmpty)
        let shown = m.handle(.visibility(allowed: true))
        #expect(shown.contains(.showNotch) && shown.contains(.reinstallTracking))
        #expect(m.phase == .idle)
        // And hover works again on the new panels.
        _ = m.handle(.enterNotch(mouseButtonsDown: false))
        #expect(m.handle(.timer(.hoverDelay, token: m.token)).contains(.showCard))
    }

    @Test func rebuildWhileTheCardIsOpenUnderThePointerDoesNotDeferForever() {
        var m = NotchMachine()
        _ = m.handle(.visibility(allowed: true))
        _ = m.handle(.enterNotch(mouseButtonsDown: false))
        _ = m.handle(.timer(.hoverDelay, token: m.token))
        _ = m.handle(.enterCard)
        // The pointer is "on the card" by the old panel's events; the rebuild forgets that.
        _ = m.handle(.rebuilt)
        #expect(!m.pointerInCard && !m.pointerInNotch && !m.pendingHide)
        _ = m.handle(.visibility(allowed: true))
        #expect(m.phase == .idle && m.notchShown)
    }

    @Test func watchdogResetsAnOpenCardTheWindowServerDoesNotShow() {
        var m = NotchMachine()
        _ = m.handle(.visibility(allowed: true))
        _ = m.handle(.shortcut)
        let t = Date(timeIntervalSince1970: 0)
        // The controller now reports kCGWindowIsOnscreen (false for the dead card) instead of isVisible (true).
        #expect(m.handle(.watchdog(cardOnScreen: false, notchOnScreen: true, now: t)).isEmpty)
        let fx = m.handle(.watchdog(cardOnScreen: false, notchOnScreen: true, now: t.addingTimeInterval(1.5)))
        #expect(fx.contains(.hideCard) && fx.contains(.reinstallTracking))
        #expect(m.phase == .idle)
    }
}
