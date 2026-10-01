import Foundation
import Testing
@testable import VigilCore

@Suite struct NotchMachineTests {
    /// A shown, idle notch.
    private func shown() -> NotchMachine {
        var m = NotchMachine()
        _ = m.handle(.visibility(allowed: true))
        return m
    }

    /// Pointer on the notch until the hover delay fires: the card is open.
    private func opened() -> NotchMachine {
        var m = shown()
        let fx = m.handle(.enterNotch(mouseButtonsDown: false))
        guard case .startTimer(.hoverDelay, let token, _)? = fx.first(where: { if case .startTimer = $0 { return true } else { return false } })
        else { fatalError("no hover timer") }
        _ = m.handle(.timer(.hoverDelay, token: token))
        return m
    }

    private func timerToken(_ fx: [NotchMachine.Effect], _ kind: NotchMachine.TimerKind) -> Int? {
        for e in fx { if case .startTimer(let k, let t, _) = e, k == kind { return t } }
        return nil
    }

    @Test func showStartsFromIdleAndReinstallsTracking() {
        var m = NotchMachine()
        #expect(m.phase == .hidden)
        let fx = m.handle(.visibility(allowed: true))
        #expect(m.phase == .idle)
        #expect(fx.contains(.showNotch))
        #expect(fx.contains(.reinstallTracking))
        #expect(fx.contains(.log("hidden → idle (visibility allowed)")))
    }

    @Test func hoverOpensAfterTheDelayAndLeavingCloses() throws {
        var m = shown()
        let fx = m.handle(.enterNotch(mouseButtonsDown: false))
        #expect(m.phase == .hovering)
        let t = try #require(timerToken(fx, .hoverDelay))
        #expect(m.handle(.timer(.hoverDelay, token: t)).contains(.showCard))
        #expect(m.phase == .open)
        _ = m.handle(.enterCard)
        _ = m.handle(.exitNotch)
        #expect(m.phase == .open) // pointer moved onto the card
        let leave = m.handle(.exitCard)
        let h = try #require(timerToken(leave, .hideDelay))
        #expect(m.handle(.timer(.hideDelay, token: h)).contains(.hideCard))
        #expect(m.phase == .idle)
    }

    @Test func draggingToTheEdgeNeverOpens() {
        var m = shown()
        #expect(m.handle(.enterNotch(mouseButtonsDown: true)).isEmpty)
        #expect(m.phase == .idle)
    }

    @Test func spaceChangeWhileHoveringKeepsTheCardOpen() {
        var m = opened()
        _ = m.handle(.enterCard)
        // Moving into a full-screen Space with "hide in full screen" on: the check says hide.
        let fx = m.handle(.visibility(allowed: false))
        #expect(m.phase == .open)
        #expect(!fx.contains(.hideNotch) && !fx.contains(.hideCard))
        #expect(m.pendingHide)
        #expect(fx.contains(.log("hide deferred: pointer on the notch")))
        // Applied only once the pointer has left both notch and card.
        let leftNotch = m.handle(.exitNotch)
        #expect(!leftNotch.contains(.hideNotch))
        #expect(m.phase == .open)
        let leftCard = m.handle(.exitCard)
        #expect(leftCard.contains(.hideNotch))
        #expect(leftCard.contains(.hideCard))
        #expect(m.phase == .hidden)
    }

    @Test func pinnedSurvivesASpaceChange() {
        var m = opened()
        _ = m.handle(.enterCard)
        _ = m.handle(.cardClick)
        #expect(m.phase == .pinned)
        _ = m.handle(.exitCard)
        _ = m.handle(.exitNotch)
        let fx = m.handle(.visibility(allowed: false))
        #expect(m.phase == .pinned)
        #expect(fx.isEmpty || fx.allSatisfy { if case .log = $0 { return true } else { return false } })
        // Unpinning applies the deferred hide.
        let close = m.handle(.closeButton)
        #expect(close.contains(.hideCard))
        #expect(close.contains(.hideNotch))
        #expect(m.phase == .hidden)
    }

    @Test func hideWithPendingTimersCausesNoLateReopenOrClose() throws {
        // Hover started, hidden before the delay fired: the old timer must not open anything.
        var m = shown()
        let t = try #require(timerToken(m.handle(.enterNotch(mouseButtonsDown: false)), .hoverDelay))
        _ = m.handle(.exitNotch)
        _ = m.handle(.visibility(allowed: false))
        #expect(m.phase == .hidden)
        #expect(m.handle(.timer(.hoverDelay, token: t)).isEmpty)
        #expect(m.phase == .hidden)

        // Card open, pointer left (hide timer pending), then hidden and shown again: the old hide timer must not
        // close a card opened later.
        var n = opened()
        let h = try #require(timerToken(n.handle(.exitNotch), .hideDelay))
        _ = n.handle(.visibility(allowed: false))
        _ = n.handle(.visibility(allowed: true))
        let t2 = try #require(timerToken(n.handle(.enterNotch(mouseButtonsDown: false)), .hoverDelay))
        _ = n.handle(.timer(.hoverDelay, token: t2))
        #expect(n.phase == .open)
        #expect(n.handle(.timer(.hideDelay, token: h)).isEmpty)
        #expect(n.phase == .open)
    }

    @Test func showAfterHideHoverWorks() throws {
        var m = opened()
        // Hidden while the pointer was on the notch: no "exited" ever arrives for that panel.
        _ = m.handle(.exitNotch)
        _ = m.handle(.visibility(allowed: false))
        #expect(m.phase == .hidden)
        #expect(!m.pointerInNotch && !m.pointerInCard)
        let show = m.handle(.visibility(allowed: true))
        #expect(show.contains(.reinstallTracking))
        #expect(m.phase == .idle)
        let t = try #require(timerToken(m.handle(.enterNotch(mouseButtonsDown: false)), .hoverDelay))
        #expect(m.handle(.timer(.hoverDelay, token: t)).contains(.showCard))
        #expect(m.phase == .open)
    }

    @Test func hideWhilePointerSitsOnTheNotchIsDeferredThenApplied() {
        var m = shown()
        _ = m.handle(.enterNotch(mouseButtonsDown: false))
        #expect(m.handle(.visibility(allowed: false)).contains(.log("hide deferred: pointer on the notch")))
        #expect(m.phase == .hovering)
        // Visibility comes back before the pointer leaves: nothing to apply.
        _ = m.handle(.visibility(allowed: true))
        #expect(!m.pendingHide)
        _ = m.handle(.exitNotch)
        #expect(m.phase == .idle)
    }

    @Test func watchdogRecoversFromACardThatVanished() {
        var m = opened()
        let t0 = Date(timeIntervalSince1970: 1000)
        // The card window is gone, but the state says open.
        #expect(m.handle(.watchdog(cardOnScreen: false, notchOnScreen: true, now: t0)).isEmpty)
        #expect(m.handle(.watchdog(cardOnScreen: false, notchOnScreen: true, now: t0.addingTimeInterval(0.5))).isEmpty)
        let fx = m.handle(.watchdog(cardOnScreen: false, notchOnScreen: true, now: t0.addingTimeInterval(1.1)))
        #expect(m.phase == .idle)
        #expect(fx.contains(.cancelTimers))
        #expect(fx.contains(.reinstallTracking))
        #expect(fx.contains { if case .log(let l) = $0 { return l.hasPrefix("watchdog:") } else { return false } })
        // And hover works again afterwards.
        let start = m.handle(.enterNotch(mouseButtonsDown: false))
        #expect(m.phase == .hovering)
        #expect(start.contains { if case .startTimer(.hoverDelay, _, _) = $0 { return true } else { return false } })
    }

    @Test func watchdogRecoversFromACardOnScreenWhileIdleAndIgnoresShortGlitches() {
        var m = shown()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = m.handle(.watchdog(cardOnScreen: true, notchOnScreen: true, now: t0))
        // Back to consistent within the grace period (e.g. the slide-out animation): no reset.
        #expect(m.handle(.watchdog(cardOnScreen: false, notchOnScreen: true, now: t0.addingTimeInterval(0.6))).isEmpty)
        #expect(m.mismatchSince == nil)
        _ = m.handle(.watchdog(cardOnScreen: true, notchOnScreen: true, now: t0.addingTimeInterval(2)))
        let fx = m.handle(.watchdog(cardOnScreen: true, notchOnScreen: true, now: t0.addingTimeInterval(3.2)))
        #expect(fx.contains(.hideCard))
        #expect(m.phase == .idle)
    }

    @Test func watchdogBringsBackAMissingNotch() {
        var m = shown()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = m.handle(.watchdog(cardOnScreen: false, notchOnScreen: false, now: t0))
        let fx = m.handle(.watchdog(cardOnScreen: false, notchOnScreen: false, now: t0.addingTimeInterval(1.5)))
        #expect(fx.contains(.showNotch))
        #expect(m.phase == .idle)
    }

    @Test func shortcutWorksWhileTheNotchIsHidden() {
        var m = NotchMachine()
        _ = m.handle(.visibility(allowed: false))
        #expect(m.phase == .hidden)
        let open = m.handle(.shortcut)
        #expect(open.contains(.showCard))
        #expect(m.phase == .pinned)
        #expect(!m.notchShown)
        let close = m.handle(.shortcut)
        #expect(close.contains(.hideCard))
        #expect(m.phase == .hidden)
    }

    @Test func clicksEscAndOutsideClicks() {
        var m = shown()
        _ = m.handle(.notchClick)
        #expect(m.phase == .pinned)
        #expect(m.handle(.escape(cardIsKey: false)).isEmpty) // Esc in another app is not ours
        _ = m.handle(.mouseDownOutside)
        #expect(m.phase == .idle)
        _ = m.handle(.notchClick)
        _ = m.handle(.cardClick)
        #expect(m.handle(.escape(cardIsKey: true)).contains(.hideCard))
        #expect(m.phase == .idle)
        // An unpinned hover card ignores outside clicks (the hover timer handles it).
        var h = opened()
        #expect(h.handle(.mouseDownOutside).isEmpty)
        #expect(h.phase == .open)
    }
}
