import AppKit
import os
import Carbon.HIToolbox
import SwiftUI
import VigilCore

/// Borderless non-activating panel. It never becomes main, and never key unless `becomesKeyOnClick` is set
/// (only the usage card, and only after the user clicks into it), so hovering never steals focus.
final class EdgePanel: NSPanel {
    /// The usage card sets this: a click into it may make it key (so it can see Esc). Hover never does.
    var becomesKeyOnClick = false
    /// Esc while this panel is key. Vigil never claims Esc system-wide.
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { becomesKeyOnClick }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape), let onEscape {
            onEscape()
            return
        }
        super.sendEvent(event)
    }
}

/// Hosting view that reports hover through its own NSTrackingArea (no global event monitors).
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    /// "notch" or "card", for the log.
    var logName = "panel"
    var onClick: (() -> Void)?
    /// With `becomesKeyOnlyIfNeeded`, a panel becomes key on a click only if the clicked view asks for it.
    var needsKeyOnClick = false
    private var area: NSTrackingArea?

    override var needsPanelToBecomeKey: Bool { needsKeyOnClick }

    /// Our tracking area is installed on the view (the health check repairs it when not).
    var hasTrackingArea: Bool { area.map { a in trackingAreas.contains { $0 === a } } ?? false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    /// Throws away the tracking area and makes a new one. Called after every show: a panel ordered out while the
    /// pointer was inside it never got its "exited", and a fresh area starts clean.
    func reinstallTracking() {
        if let area { removeTrackingArea(area) }
        area = nil
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        EdgeNotchController.log("pointer entered the \(logName)")
        onEnter()
    }

    override func mouseExited(with event: NSEvent) {
        EdgeNotchController.log("pointer left the \(logName)")
        onExit()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let onClick { onClick() } else { super.mouseDown(with: event) }
    }
}

@MainActor
@Observable
final class NotchPillState {
    var hovering = false
}

/// The thin glass pill on the right screen edge. It grows when the pointer comes close.
struct NotchPill: View {
    let state: NotchPillState
    var body: some View {
        let hover = state.hovering
        ZStack(alignment: .trailing) {
            Color.clear
            Capsule()
                .fill(.white.opacity(hover ? 0.35 : 0.18))
                .frame(width: hover ? 9 : 5, height: hover ? 72 : 56)
                .modifier(PillGlass())
                .opacity(hover ? 1 : 0.55)
                .shadow(color: .black.opacity(hover ? 0.25 : 0), radius: 4)
                .padding(.trailing, 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hover)
    }
}

private struct PillGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}

/// One notch per display (or only the main one), plus the usage card that slides out of the edge.
///
/// All behaviour lives in `NotchMachine` (hidden / idle / hovering / open / pinned); this controller only feeds it
/// events and carries out its effects. Every transition is logged (os.Logger, subsystem cz.krystof.vigil,
/// category "notch", and Vigil's own log). Visibility is re-evaluated only on a Space change, a screen-parameter
/// change and wake, debounced by 300 ms, never because one of Vigil's own windows appeared.
@MainActor
final class EdgeNotchController {
    private struct Notch {
        let screenID: CGDirectDisplayID
        let panel: EdgePanel
        let host: HoverHostingView<NotchPill>
        let state: NotchPillState
    }

    static let panelSize = NSSize(width: 24, height: 96)
    /// Keeps the notch (and so the hover zone) away from the screen corners (Hot Corners).
    static let cornerMargin: CGFloat = 80
    nonisolated private static let debounce: TimeInterval = 0.3

    private let model: AppModel
    private var machine = NotchMachine()
    private var notches: [Notch] = []
    private let cardState = UsageCardState()
    private var cardPanel: EdgePanel?
    private var cardHost: HoverHostingView<AnyView>?
    /// Screen whose notch the card is attached to.
    private var cardScreenID: CGDirectDisplayID?
    private var timers: [NotchMachine.TimerKind: Timer] = [:]
    private var orderOutWork: DispatchWorkItem?
    private var visibilityWork: DispatchWorkItem?
    private var watchdogTimer: Timer?
    private var healthTimer: Timer?
    private var rebuildWork: DispatchWorkItem?
    /// The card is checked once after each show: is it really on screen?
    private var showCheckWork: DispatchWorkItem?
    /// A rebuild that waits for the full-screen Space to go away (why it was asked for).
    private var pendingRebuild: String?
    private var shortcutToken: UInt32?
    /// Outside-click monitors (global + local), installed only while the card is pinned.
    private var outsideClickMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Last visibility decision per display, for the self-test and the log.
    private(set) var visibility: [CGDirectDisplayID: NotchVisibility] = [:]

    init(model: AppModel) {
        self.model = model
        machine.hoverDelay = model.settings.ui.hoverDelay
        let nc = NotificationCenter.default
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild("screens changed") }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleVisibilityCheck("Space changed") }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild("wake") }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild("displays woke") }
        })
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runWatchdog() }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
    }

    nonisolated private static let notchLogger = Logger(subsystem: "cz.krystof.vigil", category: "notch")

    /// One line in os_log (category notch) and in Vigil's own log as "notch: …".
    nonisolated static func log(_ line: String) {
        notchLogger.notice("\(line, privacy: .public)")
        Log.shared.info("notch: \(line)")
    }

    // MARK: on screen, as the window server sees it

    /// What the window server shows, not `isVisible`: a panel can be ordered in (isVisible true) and still not be
    /// on screen. That is how the card died after days of runtime on 30 Oct 2026: open by the state machine,
    /// `kCGWindowIsOnscreen` false, so no hover ever reached it.
    static func isOnScreen(_ window: NSWindow?) -> Bool {
        guard let window, window.windowNumber > 0,
              let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]],
              let entry = info.first else { return false }
        return entry[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    // MARK: self-healing

    /// Wake and screen changes post several notifications in a row; the rebuild runs once, after they settle.
    private func scheduleRebuild(_ reason: String) {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rebuildFromScratch(reason) } }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    /// Throws every panel away and builds new ones (the state machine starts over from hidden). Panels kept across
    /// sleep, display changes and days of runtime are what got stuck; new ones always work.
    func rebuildFromScratch(_ reason: String) {
        // A panel created while a native full-screen Space shows stays on that Space and never gets another mouse
        // event (see `rebuild()`), so the rebuild waits for a regular Space.
        if fullScreenSpaceShowing() {
            if pendingRebuild == nil { Self.log("rebuild deferred until the full-screen Space is gone (\(reason))") }
            pendingRebuild = reason
            return
        }
        pendingRebuild = nil
        Self.log("rebuilding the notch and card panels (\(reason))")
        orderOutWork?.cancel()
        orderOutWork = nil
        showCheckWork?.cancel()
        showCheckWork = nil
        send(.rebuilt)
        for n in notches { n.panel.orderOut(nil); n.panel.close() }
        notches = []
        cardPanel?.orderOut(nil)
        cardPanel?.close()
        cardPanel = nil
        cardHost = nil
        cardState.shown = false
        rebuild()
        evaluateVisibility(reason)
    }

    private func fullScreenSpaceShowing() -> Bool {
        let windows = Self.windowEntries()
        return NSScreen.screens.contains { FullScreenDetector.isNativeFullScreen(Self.spaceSnapshot(for: $0, windows: windows)) }
    }

    /// Every 30 s: is what the machine believes really on screen, with working tracking areas? Repairs and logs.
    private func checkHealth() {
        if let pending = pendingRebuild {
            rebuildFromScratch(pending) // still deferred while full screen shows
            return
        }
        let snapshot = NotchHealth.Snapshot(
            notchShown: machine.notchShown, cardShown: machine.cardShown, cardClosing: orderOutWork != nil,
            notches: Dictionary(notches.map { ($0.screenID, NotchHealth.Panel(onScreen: Self.isOnScreen($0.panel),
                                                                              trackingInstalled: $0.host.hasTrackingArea)) },
                                uniquingKeysWith: { a, _ in a }),
            card: cardPanel.map { NotchHealth.Panel(onScreen: Self.isOnScreen($0), trackingInstalled: cardHost?.hasTrackingArea ?? false) },
            wantedDisplays: Set(targetScreens().compactMap(\.displayID)))
        let problems = NotchHealth.problems(snapshot)
        guard !problems.isEmpty else { return }
        Self.log("health check repaired: " + problems.joined(separator: "; "))
        rebuildFromScratch("health check")
    }

    /// Right after the card opens: if the window server does not show it, it gets a new panel and opens again.
    private func verifyCardShown() {
        showCheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.machine.cardShown, !Self.isOnScreen(self.cardPanel) else { return }
                Self.log("repair: the card was opened but is not on screen (window \(self.cardPanel?.windowNumber ?? 0)); new card panel")
                self.cardPanel?.orderOut(nil)
                self.cardPanel?.close()
                self.cardPanel = nil
                self.cardHost = nil
                self.showCard(verify: false)
            }
        }
        showCheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Whether the pointer is over the card or a notch right now. The hide timer asks this before closing, so a
    /// missed `mouseEntered` (a transparent edge, a panel that appeared under the pointer) never closes the card.
    private func pointerOnPanels() -> (card: Bool, notch: CGDirectDisplayID?) {
        let p = NSEvent.mouseLocation
        let onCard = (cardPanel.map { Self.isOnScreen($0) && $0.frame.contains(p) }) ?? false
        let onNotch = notches.first { $0.panel.frame.insetBy(dx: -1, dy: -1).contains(p) }?.screenID
        return (onCard, onNotch)
    }

    /// "Obnovit notch" in the … menu.
    func repairFromMenu() { rebuildFromScratch("Obnovit notch") }

    /// Self-test: opens the card through the same hover path (without moving the pointer), checks that the window
    /// server shows it, and closes it again.
    func selfTestHover(_ done: @escaping @MainActor (Bool, String) -> Void) {
        guard ui.notchEnabled, !notches.isEmpty, machine.notchShown else {
            done(true, L("Hover test skipped: the notch is not shown"))
            return
        }
        guard !machine.cardShown else {
            done(Self.isOnScreen(cardPanel), Self.isOnScreen(cardPanel) ? L("Hover test: the card is open and on screen")
                                                                         : L("Hover test: the card is open but not on screen"))
            return
        }
        let id = defaultScreenID() ?? notches[0].screenID
        Self.log("self-test: hovering the notch")
        cardScreenID = id
        send(.enterNotch(mouseButtonsDown: false))
        DispatchQueue.main.asyncAfter(deadline: .now() + machine.hoverDelay + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let opened = self.machine.cardShown
                let onScreen = Self.isOnScreen(self.cardPanel)
                Self.log("self-test: card \(opened ? "opened" : "did not open"), \(onScreen ? "on" : "not on") screen")
                self.send(.exitNotch)
                if self.machine.cardShown { self.send(.closeButton) }
                let ok = opened && onScreen
                done(ok, ok ? L("Hover test: hovering the notch opened the card, and it is on screen")
                            : opened ? L("Hover test: the card opened but is not on screen")
                                     : L("Hover test: hovering the notch did not open the card"))
            }
        }
    }

    // MARK: settings

    func apply() {
        machine.hoverDelay = ui.hoverDelay
        rebuild()
        registerShortcut()
        scheduleVisibilityCheck("settings", delay: 0)
    }

    private var ui: UISettings { model.settings.ui }

    private func registerShortcut() {
        HotKeyCenter.shared.unregister(shortcutToken)
        shortcutToken = nil
        let spec = ui.shortcut
        guard spec.enabled else { return }
        shortcutToken = HotKeyCenter.shared.register(keyCode: spec.keyCode, modifiers: spec.modifiers) { [weak self] in
            guard let self else { return }
            if !self.machine.cardShown { self.cardScreenID = self.defaultScreenID() }
            self.send(.shortcut)
        }
    }

    /// The popover's usage row: opens the card pinned, like the shortcut (nothing to do when it is already shown).
    func showCardPinned() {
        guard !machine.cardShown else { return }
        cardScreenID = defaultScreenID()
        send(.shortcut)
    }

    // MARK: the machine

    private func send(_ input: NotchMachine.Input) {
        for effect in machine.handle(input) { perform(effect) }
        cardState.pinned = machine.phase == .pinned
    }

    private func perform(_ effect: NotchMachine.Effect) {
        switch effect {
        case .showNotch:
            for n in notches where !n.panel.isVisible { n.panel.orderFrontRegardless() }
        case .hideNotch:
            for n in notches {
                n.state.hovering = false
                n.panel.orderOut(nil)
            }
        case .reinstallTracking:
            for n in notches { n.host.reinstallTracking() }
            cardHost?.reinstallTracking()
        case .showCard:
            showCard()
        case .hideCard:
            hideCard()
        case .makeCardKey:
            cardPanel?.makeKey()
        case .startTimer(let kind, let token, let delay):
            timers[kind]?.invalidate()
            timers[kind] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.timerFired(kind, token: token) }
            }
        case .cancelTimers:
            timers.values.forEach { $0.invalidate() }
            timers = [:]
        case .watchOutsideClicks(let on):
            setOutsideClickMonitor(on)
        case .log(let line):
            Self.log(line)
        }
    }

    private func timerFired(_ kind: NotchMachine.TimerKind, token: Int) {
        if kind == .hideDelay {
            let at = pointerOnPanels()
            if at.card {
                Self.log("hide skipped: the pointer is on the card (no enter event came)")
                send(.enterCard)
                return
            }
            if let id = at.notch {
                Self.log("hide skipped: the pointer is on the notch (no enter event came)")
                pointerEnteredNotch(id)
                return
            }
        }
        send(.timer(kind, token: token))
    }

    // MARK: visibility

    /// Debounced: Space-switch animations and wake post several notifications in a row.
    private func scheduleVisibilityCheck(_ reason: String, delay: TimeInterval = EdgeNotchController.debounce) {
        visibilityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluateVisibility(reason) } }
        visibilityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluateVisibility(_ reason: String) {
        if let pending = pendingRebuild, !fullScreenSpaceShowing() {
            rebuildFromScratch(pending + ", after the full-screen Space")
            return
        }
        let windows = Self.windowEntries()
        for n in notches {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == n.screenID }) else { continue }
            let snapshot = Self.spaceSnapshot(for: screen, windows: windows)
            let fullScreen = FullScreenDetector.isNativeFullScreen(snapshot)
            let app = FullScreenDetector.appRevealStrip(snapshot)?.owner ?? NSWorkspace.shared.frontmostApplication?.localizedName
            visibility[n.screenID] = NotchVisibility.decide(enabled: ui.notchEnabled, onThisDisplay: true,
                                                            hideInFullScreen: ui.hideInFullScreen, fullScreen: fullScreen,
                                                            fullScreenApp: fullScreen ? app : nil)
        }
        // One machine drives all notches: the main (or card) display decides.
        let id = cardScreenID ?? defaultScreenID()
        let allowed = ui.notchEnabled && !notches.isEmpty && (id.flatMap { visibility[$0] }?.isVisible ?? true)
        if allowed != machine.visibilityAllowed || machine.notchShown != allowed {
            perform(.log("visibility check (\(reason)): \(allowed ? "show" : "hide") – \(id.flatMap { visibility[$0] }?.logText ?? "no notch")"))
        }
        send(.visibility(allowed: allowed))
    }

    /// Twice a second: does what is on screen match the machine? (It resets after a second of disagreement.)
    private func runWatchdog() {
        let cardOnScreen = Self.isOnScreen(cardPanel)
        let notchOnScreen = notches.contains { Self.isOnScreen($0.panel) }
        // A card that is still sliding out (orderOut pending) counts as the state it is heading to.
        let effectiveCard = orderOutWork != nil && !machine.cardShown ? false : cardOnScreen
        send(.watchdog(cardOnScreen: effectiveCard, notchOnScreen: notches.isEmpty ? machine.notchShown : notchOnScreen, now: Date()))
    }

    /// On-screen windows of the current Space(s), front to back, without Vigil's own: its notch and card must never
    /// change what the check sees. Owner, pid, layer, alpha and bounds need no Screen Recording permission.
    static func windowEntries() -> [WindowEntry] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return WindowEntry(owner: w[kCGWindowOwnerName as String] as? String ?? "", pid: pid,
                               layer: w[kCGWindowLayer as String] as? Int ?? 0, alpha: w[kCGWindowAlpha as String] as? Double ?? 1,
                               bounds: bounds)
        }
    }

    static func spaceSnapshot(for screen: NSScreen, windows: [WindowEntry]) -> SpaceSnapshot {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let display = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height) // CG: top-left origin
        return SpaceSnapshot(display: display, windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier)
    }

    /// One line per display for the self-test: visible or why not, the frontmost app, the full-screen state.
    func statusReport() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let windows = Self.windowEntries()
        if notches.isEmpty { return L("Notch is off") + " · " + L("frontmost app: %@", front) }
        return notches.map { n -> String in
            let screen = NSScreen.screens.first { $0.displayID == n.screenID }
            let fullScreen = screen.map { FullScreenDetector.isNativeFullScreen(Self.spaceSnapshot(for: $0, windows: windows)) } ?? false
            let state: String
            switch visibility[n.screenID] ?? .visible {
            case .visible: state = Self.isOnScreen(n.panel) ? L("Notch visible") : L("Notch should be visible but is not on screen")
            case .hiddenFullScreen(let app): state = L("Notch hidden: %@ is in full screen (⌥⌘U still opens the card)", app ?? "?")
            case .disabled: state = L("Notch is off")
            case .notOnThisDisplay: state = L("No notch on this display")
            }
            return state + " · " + L("frontmost app: %@", front) + " · " + (fullScreen ? L("full-screen Space") : L("not full screen"))
                + " · " + L("state: %@", machine.phase.rawValue)
        }.joined(separator: "\n")
    }

    /// For the self-test: what is on screen matches the state machine.
    var notchHealthy: Bool {
        (notches.contains { Self.isOnScreen($0.panel) }) == machine.notchShown || notches.isEmpty
    }

    // MARK: notches

    private func targetScreens() -> [NSScreen] {
        guard ui.notchEnabled else { return [] }
        let screens = NSScreen.screens
        return ui.notchDisplays == .main ? Array(screens.prefix(1)) : screens
    }

    private func defaultScreenID() -> CGDirectDisplayID? {
        let main = NSScreen.screens.first?.displayID
        return notch(main ?? 0) != nil ? main : notches.first?.screenID ?? main
    }

    /// Keeps one notch per target display. Existing panels are only moved, never replaced: a panel created while a
    /// full-screen Space is active stayed visible there but never received another mouse event.
    private func rebuild() {
        let screens = targetScreens()
        let wanted = Set(screens.compactMap(\.displayID))
        for n in notches where !wanted.contains(n.screenID) { n.panel.orderOut(nil) }
        notches.removeAll { !wanted.contains($0.screenID) }
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let frame = notchFrame(on: screen)
            if let existing = notch(id) {
                if existing.panel.frame != frame { existing.panel.setFrame(frame, display: true) }
                continue
            }
            let state = NotchPillState()
            let panel = EdgePanel(contentRect: frame)
            let host = HoverHostingView(rootView: NotchPill(state: state))
            host.logName = "notch"
            host.onEnter = { [weak self] in self?.pointerEnteredNotch(id) }
            host.onExit = { [weak self] in self?.pointerExitedNotch(id) }
            host.onClick = { [weak self] in
                guard let self else { return }
                if !self.machine.cardShown { self.cardScreenID = id }
                self.send(.notchClick)
            }
            panel.contentView = host
            if machine.notchShown { panel.orderFrontRegardless() }
            notches.append(Notch(screenID: id, panel: panel, host: host, state: state))
        }
        if machine.cardShown { positionCard() }
    }

    /// Flush with the visible frame's right edge (so a Dock on the right keeps the notch just inside it),
    /// at the configured height, clamped away from the corners.
    private func notchFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let size = Self.panelSize
        let half = size.height / 2
        let lo = vf.minY + Self.cornerMargin + half
        let hi = vf.maxY - Self.cornerMargin - half
        let center = lo <= hi ? min(hi, max(lo, vf.minY + vf.height * ui.notchPosition)) : vf.midY
        return NSRect(x: vf.maxX - size.width, y: (center - half).rounded(), width: size.width, height: size.height)
    }

    private func notch(_ id: CGDirectDisplayID) -> Notch? { notches.first { $0.screenID == id } }

    private func pointerEnteredNotch(_ id: CGDirectDisplayID) {
        notch(id)?.state.hovering = true
        if !machine.cardShown { cardScreenID = id }
        send(.enterNotch(mouseButtonsDown: NSEvent.pressedMouseButtons != 0))
    }

    private func pointerExitedNotch(_ id: CGDirectDisplayID) {
        notch(id)?.state.hovering = false
        send(.exitNotch)
    }

    // MARK: card

    private func ensureCard() -> (EdgePanel, HoverHostingView<AnyView>) {
        if let cardPanel, let cardHost { return (cardPanel, cardHost) }
        let panel = EdgePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400))
        panel.becomesKeyOnClick = true
        panel.onEscape = { [weak self, weak panel] in self?.send(.escape(cardIsKey: panel?.isKeyWindow ?? false)) }
        let root = AnyView(UsageCardContainer(model: model, state: cardState,
                                              onClick: { [weak self] in self?.send(.cardClick) },
                                              onClose: { [weak self] in self?.send(.closeButton) }))
        let host = HoverHostingView(rootView: root)
        host.logName = "card"
        host.needsKeyOnClick = true
        host.onEnter = { [weak self] in self?.send(.enterCard) }
        host.onExit = { [weak self] in self?.send(.exitCard) }
        panel.contentView = host
        cardPanel = panel
        cardHost = host
        return (panel, host)
    }

    /// Card panel: left of the notch column, vertically centered on the notch, inside the visible frame.
    private func positionCard() {
        guard let panel = cardPanel, let host = cardHost else { return }
        let screen = NSScreen.screens.first { $0.displayID == cardScreenID } ?? NSScreen.screens.first
        guard let screen else { return }
        let vf = screen.visibleFrame
        let size = host.fittingSize
        let notchMid = notch(cardScreenID ?? 0)?.panel.frame.midY ?? notchFrame(on: screen).midY
        var y = notchMid - size.height / 2
        y = min(vf.maxY - size.height, max(vf.minY, y))
        let frame = NSRect(x: vf.maxX - Self.panelSize.width - size.width, y: y.rounded(), width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    private func showCard(verify: Bool = true) {
        orderOutWork?.cancel()
        orderOutWork = nil
        let (panel, host) = ensureCard()
        if cardScreenID == nil { cardScreenID = defaultScreenID() }
        positionCard()
        panel.orderFrontRegardless()
        host.reinstallTracking()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { cardState.shown = true }
        if verify { verifyCardShown() }
    }

    private func hideCard() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { cardState.shown = false }
        orderOutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.orderOutWork = nil
                if !self.machine.cardShown { self.cardPanel?.orderOut(nil) }
            }
        }
        orderOutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Keeps the panel sized to its content (sessions come and go) while it is visible.
    func refresh() {
        if machine.cardShown { positionCard() }
    }

    /// Left mouse-downs only. The global monitor sees clicks in other apps; the local one sees clicks in Vigil's
    /// own windows (menu bar icon, popover) except the card and the notches, which handle their own clicks.
    private func setOutsideClickMonitor(_ on: Bool) {
        if on, outsideClickMonitors.isEmpty {
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.send(.mouseDownOutside) }
            }) {
                outsideClickMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                MainActor.assumeIsolated {
                    if let self, !self.isEdgeWindow(event.window) { self.send(.mouseDownOutside) }
                }
                return event
            }) {
                outsideClickMonitors.append(local)
            }
        } else if !on, !outsideClickMonitors.isEmpty {
            outsideClickMonitors.forEach(NSEvent.removeMonitor)
            outsideClickMonitors = []
        }
    }

    private func isEdgeWindow(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === cardPanel || notches.contains { $0.panel === window }
    }
}

/// Clips the sliding card to its panel and slides it in from the right edge.
private struct UsageCardContainer: View {
    let model: AppModel
    let state: UsageCardState
    let onClick: () -> Void
    let onClose: () -> Void

    var body: some View {
        UsageCardView(model: model, state: state, onClick: onClick, onClose: onClose)
            .padding(.vertical, 24).padding(.leading, 24).padding(.trailing, 10) // room for the glass shadow
            .offset(x: state.shown ? 0 : UsageCardView.width + 40)
            .opacity(state.shown ? 1 : 0)
            .fixedSize()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
